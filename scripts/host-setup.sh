#!/usr/bin/env bash
# host-setup.sh — install-time setup for this flake's hosts.
#
# Three modes, picked by flag:
#
#   (default)      mount existing partitions under /mnt. Idempotent.
#   --partition    DESTRUCTIVE: wipe + GPT + ESP + btrfs + subvols.
#                  Leaves nothing mounted; run the default mode after.
#   --install <h>  generate hardware-config, git add it, sanity-check
#                  via nix eval, then run nixos-install --root /mnt
#                  --flake .#<h>. Assumes /mnt is already mounted (run
#                  the default mode first if needed).
#
# Why this exists:
#   Re-entering a partially-installed system from the NixOS USB took
#   six commands of muscle memory (mount root subvol, mkdir
#   boot/home/nix, mount each subvol, mount ESP) plus an awkward
#   nixos-generate-config + git add + nixos-install dance. Each step
#   is an opportunity to silently install bootloader entries to a
#   non-ESP /mnt/boot, leave the regenerated hwconfig untracked
#   (flake silently uses the placeholder), or, in --partition mode,
#   obliterate the wrong disk. Encode the layout from
#   docs/runbooks/new-host-partitioning.md and the "git add or it
#   doesn't count" rule from AGENTS.md into one auditable script.
#
# Usage:
#   sudo ./scripts/host-setup.sh /dev/nvme0n1                # mount-only
#   sudo ./scripts/host-setup.sh /dev/nvme0n1 --partition    # destructive
#   sudo ./scripts/host-setup.sh --install pb-t480           # full install
#   sudo ./scripts/host-setup.sh --help
#
# Layout assumed (matches docs/runbooks/new-host-partitioning.md):
#   p1: 1 GiB vfat ESP                    → /mnt/boot
#   p2: btrfs filesystem, three subvols:
#        subvol=root  → /mnt
#        subvol=home  → /mnt/home
#        subvol=nix   → /mnt/nix
#
# Disk naming:
#   - NVMe disks: /dev/nvme0n1 → partitions /dev/nvme0n1p1, p2
#   - SATA/SCSI:  /dev/sda     → partitions /dev/sda1, sda2
#   - virtio:     /dev/vda     → partitions /dev/vda1, vda2
#   The script auto-detects which suffix style applies via the
#   `[0-9]$` test on the disk name (NVMe ends in a digit → needs `p`).
#
# Safety:
#   - Refuses to run as non-root (mount/mkfs/wipefs/nixos-install need it).
#   - --partition demands the literal word YES (uppercase) at an
#     interactive prompt and echoes the disk identity (model/size/
#     serial via lsblk) first.
#   - --install also demands YES, after showing the diff against the
#     committed hardware-config and the resolved root device that
#     Nix will install (via `nix eval --refresh`).
#   - Mount-only is idempotent: if a target is already correctly
#     mounted, it skips; if mounted to something else, it errors out
#     instead of clobbering.
#
# Retire when: you replace this with a disko-based declarative
#   partitioning module and ditch manual mount sequences entirely.

set -euo pipefail

# ── arg parsing ───────────────────────────────────────────────────
DISK=""
HOSTNAME=""
MODE="mount"   # one of: mount | partition | install
SHOW_HELP=0

usage() {
    sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
}

# Lightweight state machine. --install consumes the next positional
# token as the hostname; --partition is a flag toggle on top of mount;
# the bare positional is the disk (required for mount/partition,
# rejected for install).
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            SHOW_HELP=1
            shift
            ;;
        --partition)
            if [[ "$MODE" == "install" ]]; then
                echo "error: --partition and --install are mutually exclusive" >&2
                exit 2
            fi
            MODE="partition"
            shift
            ;;
        --install)
            if [[ "$MODE" == "partition" ]]; then
                echo "error: --partition and --install are mutually exclusive" >&2
                exit 2
            fi
            MODE="install"
            shift
            if [[ $# -eq 0 || "$1" =~ ^- ]]; then
                echo "error: --install requires a hostname argument" >&2
                exit 2
            fi
            HOSTNAME="$1"
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "error: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            if [[ -z "$DISK" ]]; then
                DISK="$1"
                shift
            else
                echo "error: unexpected positional arg: $1" >&2
                exit 2
            fi
            ;;
    esac
done

if (( SHOW_HELP )); then
    usage
    exit 0
fi

# Mode-specific arg validation.
case "$MODE" in
    mount|partition)
        if [[ -z "$DISK" ]]; then
            echo "error: missing disk argument" >&2
            echo "usage: $0 <disk> [--partition]" >&2
            echo "       $0 --install <hostname>" >&2
            echo "       $0 --help" >&2
            exit 2
        fi
        ;;
    install)
        if [[ -n "$DISK" ]]; then
            echo "error: --install does not take a disk argument" >&2
            echo "       (mount the disk first with: $0 <disk>)" >&2
            exit 2
        fi
        ;;
esac

# ── preconditions ─────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "error: must run as root (need mount / mkfs / wipefs / nixos-install)" >&2
    exit 2
fi

# Disk-related setup is only needed for mount/partition modes.
P1=""
P2=""
if [[ "$MODE" != "install" ]]; then
    if [[ ! -b "$DISK" ]]; then
        echo "error: $DISK is not a block device" >&2
        exit 2
    fi
    # Resolve partition suffix style. NVMe / mmcblk style ends in a
    # digit and uses pN; sd/vd/hd style appends N directly.
    case "$DISK" in
        *[0-9]) PSEP="p" ;;
        *)      PSEP=""  ;;
    esac
    P1="${DISK}${PSEP}1"
    P2="${DISK}${PSEP}2"
fi

# Required tools. lsblk + mount + umount + mkdir + mountpoint are
# coreutils/util-linux core; the rest depend on mode.
require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: required tool not found: $1" >&2
        exit 2
    fi
}
require_tool lsblk
require_tool mount
require_tool umount
require_tool findmnt
require_tool blkid

case "$MODE" in
    partition)
        require_tool wipefs
        require_tool sgdisk
        require_tool parted
        require_tool mkfs.fat
        require_tool mkfs.btrfs
        require_tool btrfs
        ;;
    install)
        require_tool git
        require_tool nix
        require_tool nixos-generate-config
        require_tool nixos-install
        require_tool diff
        ;;
esac

# ── helper: show what we're about to touch ────────────────────────
show_disk() {
    echo
    echo "Target disk: $DISK"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT,MODEL,SERIAL "$DISK" || true
    echo
}

# ── helper: mount a btrfs subvol with the standard options ────────
# Idempotent: if the target is already a mountpoint of the expected
# device+subvol, skip; otherwise mkdir + mount.
mount_subvol() {
    local subvol="$1"
    local target="$2"

    mkdir -p "$target"

    if mountpoint -q "$target"; then
        local cur_src cur_subvol
        cur_src=$(findmnt -no SOURCE "$target")
        cur_subvol=$(findmnt -no FSROOT "$target" | sed 's|^/||')
        if [[ "$cur_src" == "$P2" && "$cur_subvol" == "$subvol" ]]; then
            echo "  ok: $target already mounted ($P2 subvol=$subvol)"
            return 0
        fi
        echo "error: $target is already a mountpoint, but for a different fs/subvol" >&2
        echo "       found: $cur_src subvol=$cur_subvol" >&2
        echo "       want:  $P2 subvol=$subvol" >&2
        echo "       unmount it manually before re-running" >&2
        exit 3
    fi

    mount -o "subvol=${subvol},compress=zstd,noatime" "$P2" "$target"
    echo "  mounted: $P2 subvol=$subvol → $target"
}

# Same idempotence pattern for the ESP.
mount_esp() {
    local target="/mnt/boot"
    mkdir -p "$target"

    if mountpoint -q "$target"; then
        local cur_src
        cur_src=$(findmnt -no SOURCE "$target")
        if [[ "$cur_src" == "$P1" ]]; then
            echo "  ok: $target already mounted ($P1)"
            return 0
        fi
        echo "error: $target is already mounted from $cur_src, expected $P1" >&2
        exit 3
    fi

    mount "$P1" "$target"
    echo "  mounted: $P1 → $target"
}

# ── --partition mode: destructive bringup ─────────────────────────
do_partition() {
    show_disk

    cat <<EOF
*** DESTRUCTIVE OPERATION ***

About to:
  1. wipefs -a $DISK            (erase all filesystem signatures)
  2. sgdisk --zap-all $DISK     (clear GPT + MBR)
  3. Recreate GPT with two partitions:
       p1:  1 GiB vfat ESP   → $P1
       p2:  remainder, btrfs → $P2
  4. mkfs.fat -F 32 -n BOOT $P1
  5. mkfs.btrfs $P2
  6. Create subvolumes: root, home, nix

Anything currently on $DISK will be lost beyond recovery.

After --partition completes, nothing is mounted. Run:
  sudo $0 $DISK            # mount the new layout under /mnt
  sudo $0 --install <h>    # then generate hwconfig + install

EOF

    # First: refuse if any partition on $DISK is currently mounted.
    # findmnt returns 0 if it finds anything matching.
    if findmnt -rno SOURCE | grep -E "^${DISK}([0-9p]|$)" >/dev/null 2>&1; then
        echo "error: partitions on $DISK are currently mounted:" >&2
        findmnt -o SOURCE,TARGET,FSTYPE | grep -E "^${DISK}" >&2
        echo "       unmount them before re-running with --partition" >&2
        exit 3
    fi

    read -r -p "Type YES (uppercase) to proceed, anything else to abort: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "aborted." >&2
        exit 1
    fi

    echo
    echo ">> wiping filesystem signatures…"
    wipefs -a "$DISK"

    echo ">> zapping GPT + MBR…"
    sgdisk --zap-all "$DISK"

    echo ">> creating partitions…"
    parted -s "$DISK" -- mklabel gpt
    parted -s "$DISK" -- mkpart ESP fat32 1MiB 1025MiB
    parted -s "$DISK" -- set 1 esp on
    parted -s "$DISK" -- mkpart primary btrfs 1025MiB 100%

    # Give udev a moment to materialise the partition device nodes,
    # otherwise mkfs may race and fail with "no such device".
    udevadm settle || sleep 1

    echo ">> formatting ESP ($P1)…"
    mkfs.fat -F 32 -n BOOT "$P1"

    echo ">> formatting btrfs ($P2)…"
    mkfs.btrfs -f "$P2"

    echo ">> creating subvolumes…"
    local tmp
    tmp=$(mktemp -d)
    mount "$P2" "$tmp"
    btrfs subvolume create "$tmp/root"
    btrfs subvolume create "$tmp/home"
    btrfs subvolume create "$tmp/nix"
    umount "$tmp"
    rmdir "$tmp"

    # Done. Deliberately do NOT mount anything here — keep modes
    # tightly scoped (partition does setup only; mount is a separate
    # step). The user runs `host-setup.sh <disk>` next to mount.
    echo
    echo ">> partition + format + subvols complete on $DISK."
    echo "next steps:"
    echo "  sudo $0 $DISK              # mount the new layout under /mnt"
    echo "  sudo $0 --install <host>   # then generate hwconfig + install"
}

# ── default mode: mount existing partitions under /mnt ────────────
do_mount() {
    show_disk

    # Fail fast if expected partitions don't exist.
    if [[ ! -b "$P1" ]]; then
        echo "error: ESP partition $P1 not found" >&2
        exit 3
    fi
    if [[ ! -b "$P2" ]]; then
        echo "error: btrfs partition $P2 not found" >&2
        exit 3
    fi

    # Sanity: $P1 should be vfat, $P2 should be btrfs. blkid prints
    # nothing (and exits 2) if there's no recognised signature.
    local p1_fs p2_fs
    p1_fs=$(blkid -o value -s TYPE "$P1" 2>/dev/null || true)
    p2_fs=$(blkid -o value -s TYPE "$P2" 2>/dev/null || true)
    if [[ "$p1_fs" != "vfat" ]]; then
        echo "warning: $P1 fstype is '$p1_fs' (expected vfat). Continuing." >&2
    fi
    if [[ "$p2_fs" != "btrfs" ]]; then
        echo "error: $P2 fstype is '$p2_fs' (expected btrfs). Refusing to mount." >&2
        echo "       run with --partition to format from scratch." >&2
        exit 3
    fi

    echo ">> mounting btrfs root subvol on /mnt…"
    mount_subvol root /mnt

    echo ">> mounting btrfs home subvol on /mnt/home…"
    mount_subvol home /mnt/home

    echo ">> mounting btrfs nix subvol on /mnt/nix…"
    mount_subvol nix /mnt/nix

    echo ">> mounting ESP on /mnt/boot…"
    mount_esp

    echo
    echo ">> final mount state under /mnt:"
    findmnt -R /mnt
    echo
    echo "ready. hardware-config UUIDs:"
    echo "  /     $(blkid -s UUID -o value "$P2")  (btrfs, used for fileSystems and resumeDevice)"
    echo "  /boot $(blkid -s UUID -o value "$P1")  (vfat ESP)"
    echo
    echo "next steps:"
    echo "  sudo $0 --install <hostname>           # auto-generate hwconfig + nixos-install"
    echo "or manual:"
    echo "  nixos-generate-config --root /mnt --show-hardware-config \\"
    echo "    > /mnt/<repo>/hosts/<hostname>/hardware-configuration.nix"
    echo "  cd /mnt/<repo> && git add hosts/<hostname>/hardware-configuration.nix"
    echo "  nixos-install --root /mnt --flake .#<hostname>"
}

# ── --install mode: regen hwconfig, git add, verify, install ─────
# Walk up from cwd looking for a flake.nix. Print the directory or
# error out. We can't use `nix flake metadata` here because the user
# may have edited but not committed: --refresh + working tree
# shenanigans get involved. A plain ancestor walk is more predictable.
find_flake_root() {
    local d
    d=$(pwd)
    while [[ "$d" != "/" ]]; do
        if [[ -f "$d/flake.nix" ]]; then
            echo "$d"
            return 0
        fi
        d=$(dirname "$d")
    done
    return 1
}

do_install() {
    # 1. /mnt sanity. Need at least / and /boot mounted.
    if ! mountpoint -q /mnt; then
        echo "error: /mnt is not a mountpoint." >&2
        echo "       run: sudo $0 <disk>   first." >&2
        exit 3
    fi
    if ! mountpoint -q /mnt/boot; then
        echo "error: /mnt/boot is not a mountpoint." >&2
        echo "       run: sudo $0 <disk>   first to mount the ESP." >&2
        exit 3
    fi
    # The nixos-install bootloader install lands its entries on
    # whatever /mnt/boot is. If that's not a vfat ESP, we'd be
    # writing entries onto btrfs root and the firmware will never
    # find them. Verify.
    local boot_fs
    boot_fs=$(findmnt -no FSTYPE /mnt/boot 2>/dev/null || true)
    if [[ "$boot_fs" != "vfat" ]]; then
        echo "error: /mnt/boot fstype is '$boot_fs', expected vfat." >&2
        echo "       systemd-boot would install entries to the wrong place." >&2
        exit 3
    fi

    # 2. Locate flake root.
    local flake_root
    if ! flake_root=$(find_flake_root); then
        echo "error: no flake.nix found in cwd or any ancestor." >&2
        echo "       cd into your flake checkout and re-run." >&2
        exit 3
    fi
    echo ">> flake root: $flake_root"

    # 3. Verify the host bridge file exists. This is also a sanity
    # check on the hostname argument.
    local host_dir="$flake_root/hosts/$HOSTNAME"
    local hwcfg="$host_dir/hardware-configuration.nix"
    local host_bridge="$flake_root/flake-modules/hosts/$HOSTNAME.nix"
    if [[ ! -d "$host_dir" ]]; then
        echo "error: $host_dir does not exist" >&2
        echo "       (expected per-host directory for hardware-config + assets)" >&2
        exit 3
    fi
    if [[ ! -f "$host_bridge" ]]; then
        echo "error: $host_bridge does not exist" >&2
        echo "       (expected host bridge module)" >&2
        exit 3
    fi

    # 4. Regenerate hardware-config. Save the old one so we can show
    # a diff and roll back if the user aborts at the confirm prompt.
    local hwcfg_backup="${hwcfg}.before-install"
    if [[ -f "$hwcfg" ]]; then
        cp "$hwcfg" "$hwcfg_backup"
    fi
    echo ">> regenerating $hwcfg via nixos-generate-config --root /mnt …"
    nixos-generate-config --root /mnt --show-hardware-config > "$hwcfg"

    # 5. Show the diff. If unchanged, that's also fine (no-op).
    echo
    echo ">> diff against previously-committed hardware-config:"
    if [[ -f "$hwcfg_backup" ]]; then
        diff -u "$hwcfg_backup" "$hwcfg" || true
    else
        echo "  (no prior file existed; full content is new)"
    fi
    echo

    # 6. git add. The flake build only sees git-tracked files, even
    # for in-tree paths — this is the AGENTS.md hard rule that bites
    # everyone exactly once.
    echo ">> git add $hwcfg"
    git -C "$flake_root" add "hosts/$HOSTNAME/hardware-configuration.nix"
    echo
    echo ">> git status (the file MUST appear here as staged):"
    git -C "$flake_root" status --short -- "hosts/$HOSTNAME/hardware-configuration.nix"
    echo

    # 7. Sanity: ask Nix what root device it will install. --refresh
    # busts the flake source-copy cache. Compare to blkid's view of
    # /mnt — they MUST match or the new system won't find its root.
    echo ">> resolving fileSystems.\"/\".device via nix eval --refresh …"
    local nix_root_dev mnt_uuid mnt_dev nix_root_uuid
    nix_root_dev=$(nix eval --refresh --impure --raw \
        "$flake_root#nixosConfigurations.$HOSTNAME.config.fileSystems.\"/\".device")
    mnt_dev=$(findmnt -no SOURCE /mnt)
    mnt_uuid=$(blkid -s UUID -o value "$mnt_dev")
    # Strip the "/dev/disk/by-uuid/" prefix if present, so we can
    # compare bare UUIDs.
    nix_root_uuid="${nix_root_dev#/dev/disk/by-uuid/}"

    echo "  nix says root device: $nix_root_dev"
    echo "  /mnt is backed by:    $mnt_dev (UUID $mnt_uuid)"
    if [[ "$nix_root_uuid" != "$mnt_uuid" ]]; then
        echo
        echo "error: UUID mismatch between Nix's view and the actual /mnt." >&2
        echo "       Nix would install a system that boots looking for" >&2
        echo "       UUID $nix_root_uuid, but /mnt is $mnt_uuid." >&2
        echo "       The regenerated hardware-config didn't reach Nix." >&2
        echo "       Common causes:" >&2
        echo "         - git add silently failed (re-run, check git status)." >&2
        echo "         - flake source cache served stale content (we used" >&2
        echo "           --refresh to bust it; if you still see this, try" >&2
        echo "           rm -rf /root/.cache/nix and retry)." >&2
        exit 4
    fi
    echo "  ✓ UUIDs match."
    echo

    # 8. Confirm and run.
    echo "About to: nixos-install --root /mnt --flake $flake_root#$HOSTNAME"
    read -r -p "Type YES (uppercase) to proceed, anything else to abort: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "aborted."
        exit 1
    fi

    echo
    echo ">> running nixos-install …"
    nixos-install --root /mnt --flake "$flake_root#$HOSTNAME"
}

# ── dispatch ──────────────────────────────────────────────────────
case "$MODE" in
    mount)     do_mount ;;
    partition) do_partition ;;
    install)   do_install ;;
esac
