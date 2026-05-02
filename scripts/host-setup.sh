#!/usr/bin/env bash
# host-setup.sh — install-time setup for this flake's hosts.
#
# Modes (exactly one per invocation, picked by flag):
#
#   --mount        Mount existing partitions on the given disk under
#                  /mnt. Idempotent. This is the DEFAULT if no mode
#                  flag is given but a disk is.
#   --unmount      Recursively unmount everything under /mnt and
#                  remove the empty mountpoint dirs we own. Idempotent.
#   --partition    DESTRUCTIVE: wipe disk, write GPT + ESP + btrfs,
#                  create root/home/nix subvols. Leaves nothing
#                  mounted (run --mount after).
#   --install <h>  Generate hardware-config, patch the host bridge's
#                  resumeDevice UUID (if it has one), git add both,
#                  sanity-check via nix eval, then nixos-install
#                  --root /mnt --flake .#<h>. Assumes /mnt is
#                  already mounted. Then (if the host uses
#                  hibernate) provisions /swap/swapfile, captures
#                  the real `resume_offset`, patches it into the
#                  host bridge's boot.kernelParams, and re-runs
#                  nixos-install so the bootloader cmdline picks it
#                  up — no first-boot reboot loop required.
#   --install-hm   Trigger the home-manager-bootstrap-*.service
#                  units. Auto-detects context: if /mnt has an
#                  installed system at /mnt/etc/systemd/system, runs
#                  each user's HM activation directly via chroot
#                  (no systemd needed; useful right after
#                  nixos-install in the live USB before reboot). If
#                  /mnt is not mounted, runs against the running
#                  system via `systemctl start`. Idempotent in both
#                  modes — already-bootstrapped users are skipped via
#                  the units' ConditionPathExists guard.
#   --audio-discover  Print a ready-to-paste `audio.autoloads`
#                  entry for the host's currently-default PipeWire
#                  sink. Run this on real hardware once after
#                  installing a new host that imports
#                  flake-modules/audio.nix; paste the printed entry
#                  into the host bridge's `audio.autoloads = [ ... ]`
#                  list, replacing the `preset = "..."` field with
#                  the EasyEffects preset name you want bound to
#                  this sink. Read-only — no root, no /mnt needed.
#   --hm-switch <user>
#                  Re-run home-manager activation for <user> on the
#                  CURRENTLY-BOOTED system. Use this when you've
#                  edited a kid's HM config from p's account and
#                  want to push the change without asking the kid
#                  to log in and run home-manager themselves. Looks
#                  up homeConfigurations.<user>@<thishost> in this
#                  flake, builds the activation package, enables
#                  `loginctl` linger on <user> so their systemd-user
#                  bus exists even when not logged in, then runs the
#                  activation as <user> with the right HOME / dbus /
#                  runtime-dir env. Idempotent. Run once per user
#                  (e.g. for m and s on pb-t480, invoke twice).
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
#   sudo ./scripts/host-setup.sh /dev/nvme0n1 --mount        # mount (default)
#   sudo ./scripts/host-setup.sh /dev/nvme0n1                # same as --mount
#   sudo ./scripts/host-setup.sh --unmount                   # umount /mnt tree
#   sudo ./scripts/host-setup.sh /dev/nvme0n1 --partition    # destructive
#   sudo ./scripts/host-setup.sh --install pb-t480           # full install
#   sudo ./scripts/host-setup.sh --install-hm                # bootstrap HM
#   ./scripts/host-setup.sh --audio-discover                 # print autoload
#   sudo ./scripts/host-setup.sh --hm-switch m               # HM switch for m
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
#     Nix will install (via `nix eval --refresh`). Aborting at the
#     prompt cleanly reverts the staged hwconfig and removes the
#     backup file — no leftover state.
#   - --mount is idempotent: if a target is already correctly
#     mounted, it skips; if mounted to something else, it errors out
#     instead of clobbering. Hard-errors if ESP partition isn't vfat
#     (the failure mode that bricked previous installs by writing
#     systemd-boot entries onto btrfs root).
#   - --unmount only removes the four directories we manage
#     (/mnt/boot, /mnt/home, /mnt/nix, /mnt) and only if empty.
#
# Retire when: you replace this with a disko-based declarative
#   partitioning module and ditch manual mount sequences entirely.
# === END HELP ===

set -Eeuo pipefail

# ── arg parsing ───────────────────────────────────────────────────
DISK=""
HOSTNAME=""
TARGET_USER=""
MODE=""        # one of: mount | unmount | partition | install | install-hm | audio-discover | hm-switch
SHOW_HELP=0

usage() {
    # Print everything from line 2 down to the END HELP sentinel.
    sed -n '2,/^# === END HELP ===$/p' "$0" \
        | sed '$d' \
        | sed 's/^# \{0,1\}//'
}

set_mode() {
    local new="$1"
    if [[ -n "$MODE" && "$MODE" != "$new" ]]; then
        echo "error: mode flags are mutually exclusive (--mount/--unmount/--partition/--install/--install-hm/--audio-discover/--hm-switch)" >&2
        exit 2
    fi
    MODE="$new"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            SHOW_HELP=1
            shift
            ;;
        --mount)
            set_mode mount
            shift
            ;;
        --unmount|--umount)
            set_mode unmount
            shift
            ;;
        --partition)
            set_mode partition
            shift
            ;;
        --install)
            set_mode install
            shift
            if [[ $# -eq 0 || "$1" =~ ^- ]]; then
                echo "error: --install requires a hostname argument" >&2
                exit 2
            fi
            HOSTNAME="$1"
            shift
            ;;
        --install-hm)
            set_mode install-hm
            shift
            ;;
        --audio-discover)
            set_mode audio-discover
            shift
            ;;
        --hm-switch)
            set_mode hm-switch
            shift
            if [[ $# -eq 0 || "$1" =~ ^- ]]; then
                echo "error: --hm-switch requires a username argument" >&2
                exit 2
            fi
            TARGET_USER="$1"
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

# Default mode: if a disk was given but no flag, assume --mount.
if [[ -z "$MODE" ]]; then
    if [[ -n "$DISK" ]]; then
        MODE="mount"
    else
        echo "error: no mode and no disk given." >&2
        echo "       see: $0 --help" >&2
        exit 2
    fi
fi

# Mode-specific arg validation.
case "$MODE" in
    mount|partition)
        if [[ -z "$DISK" ]]; then
            echo "error: --$MODE requires a disk argument" >&2
            echo "usage: $0 <disk> --$MODE" >&2
            exit 2
        fi
        ;;
    unmount|install|install-hm|audio-discover|hm-switch)
        if [[ -n "$DISK" ]]; then
            echo "error: --$MODE does not take a disk argument" >&2
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
if [[ "$MODE" == "mount" || "$MODE" == "partition" ]]; then
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

case "$MODE" in
    mount)
        require_tool blkid
        ;;
    partition)
        require_tool blkid
        require_tool wipefs
        require_tool sgdisk
        require_tool parted
        require_tool mkfs.fat
        require_tool mkfs.btrfs
        require_tool btrfs
        ;;
    install)
        require_tool blkid
        require_tool git
        require_tool nix
        require_tool nixos-generate-config
        require_tool nixos-install
        require_tool diff
        ;;
    install-hm)
        require_tool systemctl
        # `nixos-enter` is only required if /mnt is in play; check
        # there in do_install_hm rather than failing here for the
        # running-system path.
        ;;
    hm-switch)
        require_tool nix
        require_tool git
        require_tool loginctl
        require_tool runuser
        require_tool id
        require_tool getent
        require_tool hostname
        require_tool systemctl
        ;;
esac

# Live USB / installer environments ship Nix without nix-command +
# flakes enabled by default. Our flake-modules/nix-settings.nix turns
# them on, but only on the *installed* system — not in the installer.
# Pass them as command-line options on every nix invocation so the
# script works regardless of /etc/nix/nix.conf in the live env.
NIX_EXTRA_OPTS=(
    --extra-experimental-features nix-command
    --extra-experimental-features flakes
)

# Substituters to make available during install. The installed system
# wires niri.cachix.org via niri-flake's NixOS module, but the live
# installer ISO doesn't have it — so without these flags niri (and
# all of its Rust crate deps) get fetched from crates.io and built
# from source, which on a slow network or a 4-core T480 fails or
# takes hours. Passing extra-substituters as a CLI option appends
# to the live env's defaults; cache.nixos.org stays in play.
#
# The public key here MUST match niri-flake's published key. If
# niri ever rotates it, update both this list and any other place
# that references it (search the repo for `Wv0OmO7P`).
NIX_SUBSTITUTER_OPTS=(
    --option extra-substituters "https://niri.cachix.org"
    --option extra-trusted-public-keys "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
)

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
        # --nofsroot strips the "[/subvol]" annotation findmnt
        # otherwise appends to btrfs SOURCE, so the comparison to
        # the bare $P2 path actually works.
        cur_src=$(findmnt --nofsroot -no SOURCE "$target")
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
        cur_src=$(findmnt --nofsroot -no SOURCE "$target")
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
  4. wipefs -a $P1 $P2          (clear stale per-partition signatures)
  5. mkfs.fat -F 32 -n BOOT $P1
  6. mkfs.btrfs -f $P2
  7. Create subvolumes: root, home, nix

Anything currently on $DISK will be lost beyond recovery.

After --partition completes, nothing is mounted. Run:
  sudo $0 $DISK --mount       # mount the new layout under /mnt
  sudo $0 --install <h>       # then generate hwconfig + install

EOF

    # Refuse if any partition on $DISK is currently mounted. Match
    # the exact partition-naming styles we know about:
    #   - sd*N / vd*N / hd*N      → ${DISK}<digits>
    #   - nvme*nN / mmcblk*       → ${DISK}p<digits>
    # Anchor with a trailing space (findmnt's column delimiter) or EOL.
    if findmnt -rno SOURCE | grep -E "^${DISK}p?[0-9]+( |$)" >/dev/null 2>&1; then
        echo "error: partitions on $DISK are currently mounted:" >&2
        findmnt -o SOURCE,TARGET,FSTYPE | grep -E "^${DISK}p?[0-9]+ " >&2 || true
        echo "       run: sudo $0 --unmount   to release /mnt first" >&2
        exit 3
    fi

    read -r -p "Type YES (uppercase) to proceed, anything else to abort: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "aborted." >&2
        exit 1
    fi

    echo
    echo ">> wiping filesystem signatures on $DISK…"
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

    echo ">> wiping per-partition signatures on $P1, $P2…"
    wipefs -a "$P1" "$P2"

    echo ">> formatting ESP ($P1)…"
    mkfs.fat -F 32 -n BOOT "$P1"

    echo ">> formatting btrfs ($P2)…"
    mkfs.btrfs -f "$P2"

    echo ">> creating subvolumes…"
    local tmp
    tmp=$(mktemp -d)
    # Guarantee cleanup of the temp mountpoint even on error mid-way.
    # shellcheck disable=SC2064
    trap "umount '$tmp' 2>/dev/null || true; rmdir '$tmp' 2>/dev/null || true" EXIT
    mount "$P2" "$tmp"
    btrfs subvolume create "$tmp/root"
    btrfs subvolume create "$tmp/home"
    btrfs subvolume create "$tmp/nix"
    umount "$tmp"
    rmdir "$tmp"
    trap - EXIT

    # Done. Deliberately do NOT mount anything here — keep modes
    # tightly scoped (partition does setup only; mount is a separate
    # step). The user runs `host-setup.sh <disk> --mount` next.
    echo
    echo ">> partition + format + subvols complete on $DISK."
    echo "next steps:"
    echo "  sudo $0 $DISK --mount        # mount the new layout under /mnt"
    echo "  sudo $0 --install <host>     # then generate hwconfig + install"
}

# ── --mount mode: mount existing partitions under /mnt ────────────
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
    # ESP fstype is a HARD error: if it's not vfat, systemd-boot
    # would write loader entries onto the wrong filesystem and the
    # firmware will boot nothing. This is the bug that bricked the
    # previous t480 install attempts.
    local p1_fs p2_fs
    p1_fs=$(blkid -o value -s TYPE "$P1" 2>/dev/null || true)
    p2_fs=$(blkid -o value -s TYPE "$P2" 2>/dev/null || true)
    if [[ "$p1_fs" != "vfat" ]]; then
        echo "error: $P1 fstype is '$p1_fs' (expected vfat)." >&2
        echo "       systemd-boot would install entries to the wrong filesystem." >&2
        echo "       run with --partition to format from scratch." >&2
        exit 3
    fi
    if [[ "$p2_fs" != "btrfs" ]]; then
        echo "error: $P2 fstype is '$p2_fs' (expected btrfs)." >&2
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
    echo "  sudo $0 --install <hostname>     # auto-generate hwconfig + nixos-install"
    echo "  sudo $0 --unmount                # release /mnt cleanly"
}

# ── --unmount mode: release /mnt tree cleanly ─────────────────────
# Idempotent: missing mountpoints are fine. Only removes directories
# we manage (boot/home/nix/mnt itself), and only if empty.
do_unmount() {
    if ! mountpoint -q /mnt && [[ ! -d /mnt ]]; then
        echo "  ok: /mnt is not present, nothing to do."
        return 0
    fi

    # umount -R unmounts /mnt and everything mounted under it in the
    # right order. Skip cleanly if /mnt itself isn't a mountpoint
    # but submounts exist (rare but possible after partial setup).
    if mountpoint -q /mnt; then
        echo ">> umount -R /mnt …"
        umount -R /mnt
    else
        # Walk submounts manually if any.
        local m
        for m in /mnt/boot /mnt/home /mnt/nix; do
            if mountpoint -q "$m"; then
                echo ">> umount $m …"
                umount "$m"
            fi
        done
    fi

    # Remove empty mountpoint dirs that we created in --mount.
    # rmdir refuses non-empty dirs, which is the desired safety.
    local d
    for d in /mnt/boot /mnt/home /mnt/nix; do
        [[ -d "$d" ]] && rmdir "$d" 2>/dev/null || true
    done
    # /mnt itself: only remove if empty AND we're sure we own it
    # (i.e. it's literally /mnt, not someone's bind-mount target).
    rmdir /mnt 2>/dev/null || true

    echo
    echo ">> /mnt state after unmount:"
    findmnt -R /mnt 2>/dev/null || echo "  (nothing mounted at /mnt)"
}

# ── --install mode: regen hwconfig, git add, verify, install ─────
# Walk up from cwd looking for a flake.nix; if that fails, fall back
# to walking up from the script's own directory (the script always
# lives at <flake_root>/scripts/host-setup.sh, so this works even
# under sudo configurations that reset PWD).
find_flake_root() {
    local d
    for d in "$(pwd)" "$(dirname "$(readlink -f "$0")")"; do
        while [[ "$d" != "/" ]]; do
            if [[ -f "$d/flake.nix" ]]; then
                echo "$d"
                return 0
            fi
            d=$(dirname "$d")
        done
    done
    return 1
}

do_install() {
    # 1. /mnt sanity. Need at least / and /boot mounted.
    if ! mountpoint -q /mnt; then
        echo "error: /mnt is not a mountpoint." >&2
        echo "       run: sudo $0 <disk> --mount   first." >&2
        exit 3
    fi
    if ! mountpoint -q /mnt/boot; then
        echo "error: /mnt/boot is not a mountpoint." >&2
        echo "       run: sudo $0 <disk> --mount   first to mount the ESP." >&2
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
        echo "error: no flake.nix found in cwd or any ancestor of either" >&2
        echo "       cwd or the script's own directory." >&2
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
    # Cleanup is handled by the abort path and the success tail.
    local hwcfg_backup="${hwcfg}.before-install"
    local had_prior=0
    if [[ -f "$hwcfg" ]]; then
        cp "$hwcfg" "$hwcfg_backup"
        had_prior=1
    fi
    echo ">> regenerating $hwcfg via nixos-generate-config --root /mnt …"
    nixos-generate-config --root /mnt --show-hardware-config > "$hwcfg"

    # 4b. If the host bridge declares a `resumeDevice = "..."` line
    # (i.e. the host imports flake-modules/battery.nix and configures
    # hibernate), patch it to point at the real btrfs UUID. Without
    # this, the placeholder all-zeros UUID lands on the kernel cmdline
    # as `resume=UUID=00000000-…` and the initrd hangs ~90s waiting
    # for that device to appear before falling through to a stuck
    # boot. The btrfs root UUID is also the swapfile's host device
    # (the swapfile lives on the root subvol's parent fs).
    local hostbridge_backup="${host_bridge}.before-install"
    local had_resume_line=0
    local mnt_dev_for_resume mnt_uuid_for_resume
    mnt_dev_for_resume=$(findmnt --nofsroot -no SOURCE /mnt)
    mnt_uuid_for_resume=$(blkid -s UUID -o value "$mnt_dev_for_resume" 2>/dev/null || true)
    if [[ -z "$mnt_uuid_for_resume" ]]; then
        echo "error: blkid could not read UUID from $mnt_dev_for_resume" >&2
        echo "       (does the device have a recognised filesystem signature?)" >&2
        # No host bridge backup yet, just clean up the hwcfg.
        if (( had_prior )); then cp "$hwcfg_backup" "$hwcfg"; else rm -f "$hwcfg"; fi
        rm -f "$hwcfg_backup"
        exit 3
    fi
    if grep -qE '^[[:space:]]*resumeDevice[[:space:]]*=' "$host_bridge"; then
        had_resume_line=1
        cp "$host_bridge" "$hostbridge_backup"
        echo ">> patching resumeDevice in $host_bridge → /dev/disk/by-uuid/$mnt_uuid_for_resume"
        # The replacement is anchored on the literal `resumeDevice =`
        # prefix and replaces the entire by-uuid path inside the
        # string. Works for both placeholder zeros and any real UUID
        # already present.
        sed -i -E \
            "s|(resumeDevice[[:space:]]*=[[:space:]]*\")/dev/disk/by-uuid/[^\"]*(\";)|\1/dev/disk/by-uuid/${mnt_uuid_for_resume}\2|" \
            "$host_bridge"
        # Sanity: confirm the replacement actually happened.
        if ! grep -qF "/dev/disk/by-uuid/$mnt_uuid_for_resume" "$host_bridge"; then
            echo "error: sed replacement of resumeDevice in $host_bridge did not stick." >&2
            echo "       check the file's resumeDevice line format matches:" >&2
            echo "         resumeDevice = \"/dev/disk/by-uuid/<uuid>\";" >&2
            cp "$hostbridge_backup" "$host_bridge"
            if (( had_prior )); then cp "$hwcfg_backup" "$hwcfg"; else rm -f "$hwcfg"; fi
            rm -f "$hwcfg_backup" "$hostbridge_backup"
            exit 3
        fi
    else
        echo ">> no resumeDevice line in $host_bridge; skipping resume patch."
    fi

    # Cleanup helper used both on abort and on success.
    cleanup_hwcfg_artifacts() {
        if [[ -f "$hwcfg_backup" ]]; then
            rm -f "$hwcfg_backup"
        fi
        if [[ -f "$hostbridge_backup" ]]; then
            rm -f "$hostbridge_backup"
        fi
    }

    # Abort handler: revert staging, restore working tree from backup,
    # remove backup. Leaves the repo bit-identical to pre-invocation.
    abort_revert() {
        echo "aborted."
        # Unstage, regardless of whether anything is actually staged.
        git -C "$flake_root" restore --staged \
            "hosts/$HOSTNAME/hardware-configuration.nix" 2>/dev/null || true
        if (( had_resume_line )); then
            git -C "$flake_root" restore --staged \
                "flake-modules/hosts/$HOSTNAME.nix" 2>/dev/null || true
        fi
        if (( had_prior )); then
            # Restore the previous file content from our backup.
            cp "$hwcfg_backup" "$hwcfg"
        else
            # No prior file existed; remove the freshly-generated one.
            rm -f "$hwcfg"
        fi
        if (( had_resume_line )); then
            cp "$hostbridge_backup" "$host_bridge"
        fi
        cleanup_hwcfg_artifacts
        exit 1
    }

    # 5. Show the diff. If unchanged, that's also fine (no-op).
    echo
    echo ">> diff of $hwcfg against previously-committed:"
    if (( had_prior )); then
        diff -u "$hwcfg_backup" "$hwcfg" || true
    else
        echo "  (no prior file existed; full content is new)"
    fi
    if (( had_resume_line )); then
        echo
        echo ">> diff of $host_bridge against previously-committed:"
        diff -u "$hostbridge_backup" "$host_bridge" || true
    fi
    echo

    # 6. git add. The flake build only sees git-tracked files, even
    # for in-tree paths — this is the AGENTS.md hard rule that bites
    # everyone exactly once. Stage both the regenerated hwconfig and
    # (if applicable) the resumeDevice-patched host bridge.
    echo ">> git add $hwcfg"
    git -C "$flake_root" add "hosts/$HOSTNAME/hardware-configuration.nix"
    if (( had_resume_line )); then
        echo ">> git add $host_bridge"
        git -C "$flake_root" add "flake-modules/hosts/$HOSTNAME.nix"
    fi

    # Assert the hwconfig actually appears as staged in `git status
    # --short`. Output prefix is two columns: index, working tree.
    # We accept A_, M_, AM, MM (anything with a non-space in col 1
    # for our path).
    local staged
    staged=$(git -C "$flake_root" status --short -- \
        "hosts/$HOSTNAME/hardware-configuration.nix" || true)
    echo ">> git status (hwconfig):"
    echo "${staged:-  (clean — file unchanged from HEAD)}"
    if [[ -n "$staged" ]]; then
        local idx_col="${staged:0:1}"
        if [[ "$idx_col" == " " || "$idx_col" == "?" ]]; then
            echo
            echo "error: git add did not stage the hwconfig file." >&2
            echo "       status line: '$staged'" >&2
            echo "       check .gitignore, submodule state, or rebase-in-progress." >&2
            abort_revert
        fi
    fi
    if (( had_resume_line )); then
        local staged_bridge
        staged_bridge=$(git -C "$flake_root" status --short -- \
            "flake-modules/hosts/$HOSTNAME.nix" || true)
        echo ">> git status (host bridge):"
        echo "${staged_bridge:-  (clean — file unchanged from HEAD)}"
        if [[ -n "$staged_bridge" ]]; then
            local idx_col_bridge="${staged_bridge:0:1}"
            if [[ "$idx_col_bridge" == " " || "$idx_col_bridge" == "?" ]]; then
                echo
                echo "error: git add did not stage the host bridge." >&2
                echo "       status line: '$staged_bridge'" >&2
                abort_revert
            fi
        fi
    fi
    echo

    # 7. Sanity: ask Nix what root device it will install. --refresh
    # busts the flake source-copy cache. Compare to blkid's view of
    # /mnt — they MUST match or the new system won't find its root.
    echo ">> resolving fileSystems.\"/\".device via nix eval --refresh …"
    local nix_root_dev mnt_uuid mnt_dev nix_root_uuid nix_eval_rc
    # Capture exit code separately so a non-zero `nix eval` (network
    # fetch failure, store permission issues, eval error, etc.) shows
    # a clear diagnostic instead of `set -e` killing us silently via
    # the $(...) substitution. Stderr passes through to the user.
    set +e
    nix_root_dev=$(nix "${NIX_EXTRA_OPTS[@]}" "${NIX_SUBSTITUTER_OPTS[@]}" eval --refresh --impure --raw \
        "$flake_root#nixosConfigurations.$HOSTNAME.config.fileSystems.\"/\".device")
    nix_eval_rc=$?
    set -e
    if (( nix_eval_rc != 0 )); then
        echo
        echo "error: nix eval failed (exit $nix_eval_rc)." >&2
        echo "       see stderr above for the actual failure. Common causes" >&2
        echo "       on a live installer ISO:" >&2
        echo "         - network: --refresh re-fetches every flake input" >&2
        echo "           (niri, nixos-hardware, etc). Check connectivity." >&2
        echo "         - flake input fetch rate-limited (github 60 req/h" >&2
        echo "           unauthenticated). Wait or set GITHUB_TOKEN." >&2
        echo "         - host bridge module evaluation error. Try without" >&2
        echo "           --refresh by re-running the same command." >&2
        echo "         - missing tool in installer (git, etc)." >&2
        abort_revert
    fi
    if [[ -z "$nix_root_dev" ]]; then
        echo
        echo "error: nix eval succeeded but returned empty string." >&2
        echo "       expected /dev/disk/by-uuid/<uuid> for fileSystems.\"/\".device" >&2
        abort_revert
    fi
    # findmnt's default SOURCE output annotates btrfs subvolumes as
    # "/dev/foo[/subvol]". --nofsroot strips the bracketed part so
    # blkid gets a bare device path. Without this, blkid gets handed
    # "/dev/nvme0n1p2[/root]", returns empty + exit 2, set -e fires,
    # script dies silently mid-substitution.
    mnt_dev=$(findmnt --nofsroot -no SOURCE /mnt)
    if [[ -z "$mnt_dev" ]]; then
        echo "error: findmnt --nofsroot -no SOURCE /mnt returned empty" >&2
        abort_revert
    fi
    mnt_uuid=$(blkid -s UUID -o value "$mnt_dev" 2>/dev/null || true)
    if [[ -z "$mnt_uuid" ]]; then
        echo "error: blkid could not read UUID from $mnt_dev" >&2
        echo "       (does the device have a recognised filesystem signature?)" >&2
        abort_revert
    fi
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
        abort_revert
    fi
    echo "  ✓ root UUIDs match."

    # 7b. If the host has a resumeDevice, verify Nix will install
    # with the patched value (not the placeholder zeros). This
    # catches the bug where the host bridge edit didn't actually
    # reach Nix (stale cache, .gitignore, etc) — the system would
    # boot but hang in initrd waiting for the placeholder UUID.
    if (( had_resume_line )); then
        echo
        echo ">> resolving boot.resumeDevice via nix eval --refresh …"
        local nix_resume_dev nix_resume_uuid resume_eval_rc
        set +e
        nix_resume_dev=$(nix "${NIX_EXTRA_OPTS[@]}" "${NIX_SUBSTITUTER_OPTS[@]}" eval --refresh --impure --raw \
            "$flake_root#nixosConfigurations.$HOSTNAME.config.boot.resumeDevice")
        resume_eval_rc=$?
        set -e
        if (( resume_eval_rc != 0 )); then
            echo "error: nix eval boot.resumeDevice failed (exit $resume_eval_rc)." >&2
            abort_revert
        fi
        nix_resume_uuid="${nix_resume_dev#/dev/disk/by-uuid/}"
        echo "  nix says resumeDevice: $nix_resume_dev"
        if [[ "$nix_resume_uuid" == "00000000-0000-0000-0000-000000000000" ]]; then
            echo
            echo "error: boot.resumeDevice still resolves to the all-zeros placeholder." >&2
            echo "       The sed patch of $host_bridge didn't reach Nix." >&2
            echo "       The booted kernel would hang in initrd waiting for that UUID." >&2
            abort_revert
        fi
        if [[ "$nix_resume_uuid" != "$mnt_uuid" ]]; then
            echo
            echo "error: resumeDevice UUID does not match /mnt." >&2
            echo "       resumeDevice: $nix_resume_uuid" >&2
            echo "       /mnt:         $mnt_uuid" >&2
            echo "       (For our btrfs-swapfile-on-root layout these MUST match.)" >&2
            abort_revert
        fi
        echo "  ✓ resumeDevice UUID matches root."
    fi
    echo

    # 8. Confirm and run.
    echo "About to: nixos-install --root /mnt --flake $flake_root#$HOSTNAME"
    read -r -p "Type YES (uppercase) to proceed, anything else to abort: " confirm
    if [[ "$confirm" != "YES" ]]; then
        abort_revert
    fi

    echo
    echo ">> running nixos-install …"
    # nixos-install passes --option <key> <value> through to its
    # internal nix invocations. extra-experimental-features takes a
    # space-separated list. Without this, nixos-install fails the
    # same way nix eval did on a stock installer ISO. Substituter
    # options similarly extend the live env's defaults — they make
    # niri.cachix.org reachable so niri's Rust crates don't get
    # source-fetched + built (the failure mode that crashed earlier
    # t480 install attempts when crates.io was unreachable).
    nixos-install --root /mnt --flake "$flake_root#$HOSTNAME" \
        --option extra-experimental-features "nix-command flakes" \
        --option extra-substituters "https://niri.cachix.org" \
        --option extra-trusted-public-keys \
            "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="

    # 9. Swapfile provisioning + resume_offset capture.
    # Skipped automatically for hosts that don't use hibernate (i.e.
    # don't import battery.nix and therefore don't have a
    # `resume_offset=` in boot.kernelParams). Hosts that do use
    # hibernate get their swapfile created here and their host
    # bridge patched with the real resume_offset, then nixos-install
    # is re-invoked to bake the new cmdline into the bootloader
    # entries — eliminating the "first boot has wrong cmdline,
    # journal-grep, edit, rebuild, reboot" round trip.
    provision_swap_and_offset

    # 10. Cleanup + post-install message.
    do_install_post
}

# Helper called from do_install only. Decoupled because it has its
# own diagnostics and abort path. Exits via abort_revert on hard
# failure; returns normally (no error) when the host doesn't use
# hibernate (no resume_offset in kernelParams).
provision_swap_and_offset() {
    echo
    echo ">> checking if host uses hibernate (boot.kernelParams resume_offset)…"

    # Read kernelParams as a JSON list, look for any entry starting
    # with `resume_offset=`. If absent, this host doesn't hibernate;
    # silently skip swap provisioning.
    local kparams_json has_resume_offset cur_resume_offset swap_size_mib
    set +e
    kparams_json=$(nix "${NIX_EXTRA_OPTS[@]}" "${NIX_SUBSTITUTER_OPTS[@]}" eval --impure --json \
        "$flake_root#nixosConfigurations.$HOSTNAME.config.boot.kernelParams")
    local rc=$?
    set -e
    if (( rc != 0 )); then
        echo "warn: could not read boot.kernelParams (exit $rc); skipping swap provisioning." >&2
        return 0
    fi

    # Match any entry of the form `resume_offset=<digits>`. We use a
    # tiny inline jq via nix run to keep this dependency-free on the
    # installer ISO; if jq isn't around, fall back to grep on the
    # JSON text (good enough for our well-formed string list).
    has_resume_offset=$(printf '%s' "$kparams_json" \
        | grep -oE '"resume_offset=[0-9]+"' | head -1 || true)
    if [[ -z "$has_resume_offset" ]]; then
        echo "  host has no resume_offset in kernelParams — not a hibernate host."
        echo "  skipping swapfile provisioning."
        return 0
    fi
    cur_resume_offset=$(printf '%s' "$has_resume_offset" \
        | sed -E 's/^"resume_offset=([0-9]+)"$/\1/')
    echo "  host uses hibernate; current kernelParams resume_offset=$cur_resume_offset"

    # Read swap size from the host config so we don't hardcode 32.
    set +e
    swap_size_mib=$(nix "${NIX_EXTRA_OPTS[@]}" "${NIX_SUBSTITUTER_OPTS[@]}" eval --impure --raw \
        --apply 'devs: toString ((builtins.head devs).size)' \
        "$flake_root#nixosConfigurations.$HOSTNAME.config.swapDevices")
    rc=$?
    set -e
    if (( rc != 0 )) || [[ -z "$swap_size_mib" ]]; then
        echo "error: could not read swapDevices[0].size from $HOSTNAME config." >&2
        echo "       (size is in MiB; expected an integer)" >&2
        abort_revert
    fi
    echo "  swap size from config: ${swap_size_mib} MiB"

    # 1. Create /mnt/swap dir and the swapfile if missing. We
    # mirror NixOS's mkswap-swap-swapfile.service btrfs path
    # exactly (`btrfs filesystem mkswapfile --size NM --uuid clear`)
    # so first-boot's mkswap service finds the file already at the
    # right size and is a no-op. Idempotent: skip if file exists at
    # the right size.
    local swap_path=/mnt/swap/swapfile
    mkdir -p /mnt/swap

    local need_create=1
    if [[ -f "$swap_path" ]]; then
        local cur_size_mib
        cur_size_mib=$(( $(stat -c %s "$swap_path") / 1024 / 1024 ))
        if (( cur_size_mib == swap_size_mib )); then
            echo "  /swap/swapfile already exists at ${cur_size_mib} MiB (matches config) — reusing."
            need_create=0
        else
            echo "  /swap/swapfile exists at ${cur_size_mib} MiB but config wants ${swap_size_mib} MiB — recreating."
            rm -f "$swap_path"
        fi
    fi

    if (( need_create )); then
        echo ">> creating /swap/swapfile (${swap_size_mib} MiB) via btrfs filesystem mkswapfile …"
        # `--uuid clear` matches NixOS's invocation; without it the
        # file gets a random UUID that mismatches the kernel's
        # expectation in some kernel versions. The size flag accepts
        # M / MiB / G / GiB suffixes; we pass MiB explicitly.
        btrfs filesystem mkswapfile --size "${swap_size_mib}M" --uuid clear "$swap_path"
    fi

    # 2. Capture resume_offset.
    local offset
    set +e
    offset=$(btrfs inspect-internal map-swapfile -r "$swap_path")
    rc=$?
    set -e
    if (( rc != 0 )) || [[ -z "$offset" ]]; then
        echo "error: btrfs inspect-internal map-swapfile failed for $swap_path." >&2
        abort_revert
    fi
    echo "  resume_offset captured: $offset"

    # 3. If the host bridge already has the right offset, we're
    # done — no patch needed, no rebuild needed.
    if [[ "$cur_resume_offset" == "$offset" ]]; then
        echo "  ✓ host bridge already has correct resume_offset=$offset; no patch needed."
        return 0
    fi

    echo ">> patching resume_offset in $host_bridge: $cur_resume_offset → $offset"
    # If we haven't already backed up the host bridge (because no
    # resumeDevice patch happened earlier — unusual, but possible if
    # someone runs this on a host that has resume_offset but no
    # resumeDevice, which would be a misconfigured battery.nix
    # consumer), back it up now so the abort path can roll back.
    if (( ! had_resume_line )); then
        cp "$host_bridge" "$hostbridge_backup"
        had_resume_line=1
    fi

    # The replacement is anchored on `resume_offset=` inside the
    # kernelParams list. Matches `"resume_offset=N"` (with quotes)
    # since that's how Nix string literals appear in source. We use
    # | as the sed delimiter to avoid colliding with the value.
    sed -i -E \
        "s|\"resume_offset=[0-9]+\"|\"resume_offset=${offset}\"|" \
        "$host_bridge"

    if ! grep -qF "\"resume_offset=${offset}\"" "$host_bridge"; then
        echo "error: sed replacement of resume_offset in $host_bridge did not stick." >&2
        echo "       check the file's kernelParams line format matches:" >&2
        echo "         boot.kernelParams = [ \"resume_offset=N\" ];" >&2
        cp "$hostbridge_backup" "$host_bridge"
        abort_revert
    fi

    # 4. Stage the patched host bridge (it's already backed up;
    # the existing abort_revert handles rollback). git add is fine
    # to call again even if it was added earlier for resumeDevice.
    echo ">> git add $host_bridge"
    git -C "$flake_root" add "flake-modules/hosts/$HOSTNAME.nix"

    # 5. Verify Nix sees the new offset.
    echo ">> verifying boot.kernelParams via nix eval --refresh …"
    local kparams_after rc2
    set +e
    kparams_after=$(nix "${NIX_EXTRA_OPTS[@]}" "${NIX_SUBSTITUTER_OPTS[@]}" eval --refresh --impure --json \
        "$flake_root#nixosConfigurations.$HOSTNAME.config.boot.kernelParams")
    rc2=$?
    set -e
    if (( rc2 != 0 )); then
        echo "error: nix eval (post-patch) failed (exit $rc2)." >&2
        abort_revert
    fi
    if ! printf '%s' "$kparams_after" | grep -qE "\"resume_offset=${offset}\""; then
        echo
        echo "error: boot.kernelParams still doesn't contain resume_offset=$offset." >&2
        echo "       resolved kernelParams: $kparams_after" >&2
        abort_revert
    fi
    echo "  ✓ Nix sees resume_offset=$offset"

    # 6. Re-run nixos-install to bake the new cmdline into the
    # bootloader entries. Cheap because the store is already
    # populated; only the new system closure (with the patched
    # cmdline) and the bootloader entries get rebuilt + written.
    echo
    echo ">> re-running nixos-install to update bootloader cmdline …"
    nixos-install --root /mnt --flake "$flake_root#$HOSTNAME" --no-root-passwd \
        --option extra-experimental-features "nix-command flakes" \
        --option extra-substituters "https://niri.cachix.org" \
        --option extra-trusted-public-keys \
            "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
    echo "  ✓ bootloader updated; first boot will resume correctly from hibernate."
}

do_install_post() {
    # On success, drop the backup. We leave the working-tree change
    # in place — it represents the actual hardware UUIDs of this
    # machine and should be committed + pushed once the new system
    # boots and you can verify everything works.
    cleanup_hwcfg_artifacts

    cat <<EOF

>> nixos-install finished.

Next steps (in order):

  1. Set passwords for all interactive users (initialPassword in the
     host bridge is just "changeme" so login works exactly once):

       nixos-enter --root /mnt -c 'passwd p'
       nixos-enter --root /mnt -c 'passwd m'    # if applicable
       nixos-enter --root /mnt -c 'passwd s'    # if applicable

  2. (Optional, but recommended) Bootstrap home-manager profiles
     before reboot. Runs each user's HM activation via nixos-enter
     into /mnt — saves a reboot's worth of "did the units fire?"
     uncertainty:

       sudo $0 --install-hm

     If skipped, the same units run on first boot via systemd
     (gated on network-online.target; they self-retry on the next
     boot if WiFi isn't up yet).

  3. Release /mnt and reboot:

       sudo $0 --unmount
       reboot

  4. After first boot:

       - The hwconfig + resumeDevice + resume_offset are already in
         the working tree (auto-staged by --install). Verify the
         system boots and works, then:
           git status                                  # review
           git diff --cached                           # review staged
           git commit -m "<host>: real hardware config"
           git push
       - If you skipped --install-hm in step 2, check the bootstrap
         units now:
           systemctl status 'home-manager-bootstrap-*.service'
         Re-trigger them if any failed (e.g. WiFi wasn't up yet):
           sudo $0 --install-hm
       - Hibernate-resume is already wired correctly. Test by
         triggering a manual hibernate ('systemctl hibernate') and
         confirming wake restores the session. If resume fails,
         re-run sudo $0 --install <hostname> to re-capture the
         offset (rare; only needed if the swapfile got recreated).

EOF
}

# ── --install-hm mode: trigger home-manager-bootstrap-* services ──
# Two contexts:
#   1. /mnt is mounted AND has /mnt/etc/systemd/system populated
#      (i.e. nixos-install just finished, we're still on the live
#      USB before reboot): chroot in and run each unit's ExecStart
#      directly. Bypasses systemd entirely — manually checks the
#      ConditionPathExists guard since we can't ask systemd to do it.
#   2. /mnt is empty / not a mountpoint (running on the booted
#      installed system): use systemctl reset-failed + start, which
#      respects the units' built-in ConditionPathExists, network
#      ordering, environment, etc.
#
# Both modes are idempotent. Re-running after fixing whatever blocked
# a previous attempt (no WiFi, etc.) just retries the not-yet-bootstrapped
# users; already-bootstrapped users are no-ops.
do_install_hm() {
    local sysroot
    if mountpoint -q /mnt && [[ -d /mnt/etc/systemd/system ]]; then
        sysroot="/mnt"
        echo ">> detected installed system at /mnt — using chroot path"
    else
        sysroot=""
        echo ">> running against the booted system via systemctl"
    fi

    local unit_dir
    if [[ -n "$sysroot" ]]; then
        unit_dir="$sysroot/etc/systemd/system"
    else
        unit_dir="/etc/systemd/system"
    fi

    # Enumerate units. shopt nullglob so the loop is empty (not the
    # literal pattern) when no units are present.
    shopt -s nullglob
    local units=( "$unit_dir"/home-manager-bootstrap-*.service )
    shopt -u nullglob

    if (( ${#units[@]} == 0 )); then
        echo "error: no home-manager-bootstrap-*.service units found in $unit_dir" >&2
        echo "       did the host bridge import config.flake.modules.nixos.home-manager-bootstrap?" >&2
        echo "       (and was the system rebuilt with that change?)" >&2
        exit 3
    fi

    echo ">> found ${#units[@]} bootstrap unit(s):"
    local u
    for u in "${units[@]}"; do
        echo "   - $(basename "$u")"
    done
    echo

    if [[ -n "$sysroot" ]]; then
        require_tool nixos-enter
        do_install_hm_chroot "$sysroot" "${units[@]}"
    else
        do_install_hm_running "${units[@]}"
    fi
}

# Running-system path: hand off to systemd. It already knows how to
# wait for network-online, run as the right user, set environment,
# and respect ConditionPathExists.
do_install_hm_running() {
    local units=( "$@" )
    local u name rc

    # Clear failed state so units that previously failed (e.g. due to
    # network race on first boot) can be re-tried.
    for u in "${units[@]}"; do
        name=$(basename "$u")
        systemctl reset-failed "$name" 2>/dev/null || true
    done

    local any_failed=0
    for u in "${units[@]}"; do
        name=$(basename "$u")
        echo ">> systemctl start $name"
        # `start` blocks until oneshot units finish (success or fail).
        # Tolerate failure here — we want to attempt every user even
        # if one fails, then summarise.
        set +e
        systemctl start "$name"
        rc=$?
        set -e
        if (( rc != 0 )); then
            any_failed=1
            echo "   ✗ start returned $rc"
        else
            echo "   ✓ ok"
        fi
    done

    echo
    echo ">> status summary:"
    for u in "${units[@]}"; do
        name=$(basename "$u")
        # is-active returns "active", "failed", "inactive", etc.
        # ConditionPathExists-skipped units show as "inactive" with
        # SubState=condition; treat that as success.
        local state substate
        state=$(systemctl show -p ActiveState --value "$name" 2>/dev/null || echo "?")
        substate=$(systemctl show -p SubState --value "$name" 2>/dev/null || echo "?")
        case "$state/$substate" in
            active/exited)            echo "   ✓ $name: ran successfully" ;;
            inactive/dead)            echo "   ✓ $name: skipped (ConditionPathExists — already bootstrapped)" ;;
            failed/*)
                echo "   ✗ $name: FAILED"
                echo "       inspect: journalctl -u $name -e --no-pager"
                any_failed=1
                ;;
            *)
                echo "   ? $name: $state/$substate"
                ;;
        esac
    done

    if (( any_failed )); then
        echo
        echo ">> at least one bootstrap failed. Common causes:"
        echo "     - no network (this unit waits for network-online.target)."
        echo "       Connect WiFi via the desktop, then re-run."
        echo "     - existing non-symlink ~/.config/<thing>/<file> blocking HM."
        echo "       Inspect: journalctl -u home-manager-bootstrap-<user>"
        echo "       Fix: rm the offending file, re-run --install-hm."
        exit 4
    fi
    echo
    echo ">> all bootstrap units settled."
}

# Chroot path: parse each unit's ExecStart + User, run the activation
# script via nixos-enter. nixos-enter mounts /proc, /sys, /dev, and a
# few bind mounts inside /mnt before exec-ing into a chroot, which is
# everything HM activation needs.
do_install_hm_chroot() {
    local sysroot="$1"; shift
    local units=( "$@" )
    local u name user activate any_failed=0

    for u in "${units[@]}"; do
        name=$(basename "$u")
        # Parse "User=…" and "ExecStart=…" lines. systemd allows
        # multiple ExecStart entries; we only emit one, so head -1 is
        # safe. The unit file in $unit_dir may itself be a symlink
        # into /nix/store; that's fine, grep follows it.
        user=$(grep -E '^User=' "$u" | head -1 | sed 's/^User=//')
        activate=$(grep -E '^ExecStart=' "$u" | head -1 | sed 's/^ExecStart=//')
        if [[ -z "$user" || -z "$activate" ]]; then
            echo "error: could not parse User=/ExecStart= from $u" >&2
            any_failed=1
            continue
        fi

        # Manual ConditionPathExists check: skip already-bootstrapped
        # users so re-runs are no-ops, matching the systemd path.
        local profile_link="$sysroot/home/${user}/.local/state/nix/profiles/home-manager"
        if [[ -e "$profile_link" ]]; then
            echo ">> $name: already bootstrapped (skipped)"
            continue
        fi

        echo ">> $name: activating as $user via nixos-enter $sysroot"
        # `runuser -l` gives us a proper login shell with HOME and
        # XDG_* set from /etc/passwd. We then exec the activate
        # script. Without -l, HOME is root's and HM writes its
        # state into /root/.local — broken.
        set +e
        nixos-enter --root "$sysroot" -c \
            "runuser -l '$user' -c '$activate'"
        local rc=$?
        set -e
        if (( rc != 0 )); then
            echo "   ✗ activate returned $rc"
            any_failed=1
        else
            echo "   ✓ ok"
        fi
    done

    if (( any_failed )); then
        echo
        echo ">> at least one bootstrap failed."
        echo "   The installed system is otherwise fine — reboot and re-run"
        echo "   sudo $0 --install-hm   on the booted system to retry."
        exit 4
    fi
    echo
    echo ">> all bootstrap units settled."
}

# ── audio-discover ─────────────────────────────────────────────────
# Print a `audio.autoloads` list entry for the host's currently-default
# PipeWire sink. Use this once on real hardware after wiring a host's
# `audio.presetsDir`, then paste the printed entry into the host
# bridge's `audio.autoloads = [ ... ]` list with the desired preset
# name.
#
# Reads:
#   - wpctl inspect @DEFAULT_AUDIO_SINK@   for node.name + node.description
#   - wpctl status                          for the active card profile name
#
# No root required; no /mnt; no flake build. Pure read-only probe of
# the running PipeWire daemon.
do_audio_discover() {
    if ! command -v wpctl >/dev/null 2>&1; then
        echo "error: wpctl not found in PATH." >&2
        echo "       wpctl ships with wireplumber; this host should have"
        echo "       it via flake-modules/audio.nix's NixOS-side import." >&2
        exit 1
    fi

    # Probe the default sink. wpctl inspect emits indented "key = value"
    # lines plus property "key = \"value\"" lines.
    local inspect
    if ! inspect=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>&1); then
        echo "error: \`wpctl inspect @DEFAULT_AUDIO_SINK@\` failed:" >&2
        echo "$inspect" >&2
        echo
        echo "Is PipeWire running? Try: systemctl --user status pipewire wireplumber" >&2
        exit 1
    fi

    # Parse the lines we care about. wpctl prints e.g.
    #   * node.name = "alsa_output.pci-0000_00_1f.3.analog-stereo"
    #     node.description = "Built-in Audio Analog Stereo"
    #     device.profile.name = "analog-stereo"   (sometimes; see fallback)
    local node_name node_desc profile_name
    node_name=$(printf '%s\n' "$inspect" \
        | sed -n 's/^[* ]*node\.name = "\(.*\)"$/\1/p' \
        | head -n1)
    node_desc=$(printf '%s\n' "$inspect" \
        | sed -n 's/^[* ]*node\.description = "\(.*\)"$/\1/p' \
        | head -n1)
    # Some nodes don't carry a card profile property directly; fall back
    # to api.alsa.pcm.stream or device.profile.name. The autoload-rule
    # filename uses whatever string EE picked when creating the rule, so
    # the safest bet is the ALSA card profile name from the parent
    # device. Get it via the parent device id if present.
    profile_name=$(printf '%s\n' "$inspect" \
        | sed -n 's/^[* ]*device\.profile\.name = "\(.*\)"$/\1/p' \
        | head -n1)

    if [[ -z "$node_name" ]]; then
        echo "error: could not parse node.name from wpctl inspect output." >&2
        echo "Raw output for debugging:" >&2
        echo "$inspect" >&2
        exit 1
    fi

    # Fallback for profile_name: derive from the node.name suffix. For
    # PipeWire HDA sinks the name has the form
    #   alsa_output.<bus>.<profile>
    # where <profile> is e.g. "analog-stereo", "hdmi-stereo". For the
    # SOF-driven X1 Yoga path it's "platform-skl_hda_dsp_generic.HiFi__Speaker__sink"
    # and the user-facing profile is the part after "HiFi__" (e.g.
    # "Speaker"). We give a reasonable guess and prompt the user to
    # double-check.
    if [[ -z "$profile_name" ]]; then
        if [[ "$node_name" == *.HiFi__*__sink ]]; then
            # SOF-style: extract between "HiFi__" and "__sink"
            profile_name="${node_name##*.HiFi__}"
            profile_name="${profile_name%__sink}"
        else
            # Plain HDA: take the suffix after the last dot.
            profile_name="${node_name##*.}"
        fi
    fi

    # If description is empty, leave it as a placeholder.
    if [[ -z "$node_desc" ]]; then
        node_desc="(unknown — set me to match \`wpctl status\`)"
    fi

    cat <<EOF
# Paste this into the host bridge's \`audio.autoloads = [ ... ]\`
# (e.g. flake-modules/hosts/<this-host>.nix), replacing the
# preset = "..." value with the EasyEffects preset name you want
# bound to this sink (one of the .json files under
# hosts/<this-host>/audio-presets/, without the .json extension).
{
  device = "$node_name";
  profile = "$profile_name";
  description = "$node_desc";
  preset = "T480-Music";  # ← change to your preset name
}
EOF
}

# ── --hm-switch mode: re-run home-manager activation for a user ───
# Common case: p edits a kid's HM config in this flake from p's
# account on the kid's machine, then wants the change applied to the
# kid's profile without making the kid log in and run home-manager
# themselves.
#
# Pipeline:
#   1. Resolve flake root + this host's name (via `hostname`).
#   2. Validate the target user exists, has a home dir, and that
#      `homeConfigurations.<user>@<thishost>` exists in this flake.
#   3. Refuse if TARGET_USER == invoker; that user should just run
#      `home-manager switch --flake .#'<self>@<host>'` directly,
#      which avoids the whole linger/sudo/dbus dance.
#   4. `loginctl enable-linger <user>` — keeps `systemd --user` for
#      <user> running across logout. Required because HM activation
#      reloads the user's systemd-user units (easyeffects, idled,
#      …); without a user-bus, those reloads fail. Idempotent.
#   5. Build the activation package via the same nix-command flags
#      we use for --install (so we work on installer ISOs that don't
#      have flakes/nix-command in /etc/nix/nix.conf).
#   6. Run the activation script as <user> via `runuser -l`, with
#      XDG_RUNTIME_DIR + DBUS_SESSION_BUS_ADDRESS exported so
#      systemd-user IPC works.
#
# Read-only on the flake source tree — no commits, no pushes, no
# git mutations. The activation itself writes only to <user>'s home
# and their HM profile generation in /nix/var/nix/profiles/per-user
# /<user>/.
do_hm_switch() {
    # 1. Flake root + host name.
    local flake_root
    if ! flake_root=$(find_flake_root); then
        echo "error: no flake.nix found in cwd or any ancestor of either" >&2
        echo "       cwd or the script's own directory." >&2
        echo "       cd into your flake checkout and re-run." >&2
        exit 3
    fi
    echo ">> flake root: $flake_root"

    local host_name
    host_name=$(hostname)
    if [[ -z "$host_name" ]]; then
        echo "error: hostname returned empty" >&2
        exit 3
    fi
    local hm_id="${TARGET_USER}@${host_name}"
    echo ">> target HM config: $hm_id"

    # 2. Validate target user.
    if ! getent passwd "$TARGET_USER" >/dev/null; then
        echo "error: user '$TARGET_USER' does not exist on this system." >&2
        echo "       (try \`getent passwd | cut -d: -f1\` to list users)" >&2
        exit 3
    fi
    local target_uid target_home
    target_uid=$(id -u "$TARGET_USER")
    target_home=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [[ -z "$target_home" || ! -d "$target_home" ]]; then
        echo "error: home directory '$target_home' for user '$TARGET_USER' does not exist." >&2
        exit 3
    fi
    echo ">> target user: $TARGET_USER (uid=$target_uid, home=$target_home)"

    # 3. Refuse self-target — pointless extra layer of sudo/runuser
    # and dbus juggling; the user should just call home-manager
    # directly.
    local invoker_user="${SUDO_USER:-${USER:-}}"
    if [[ -z "$invoker_user" ]]; then
        # Fallback: derive from real uid.
        invoker_user=$(id -un "${SUDO_UID:-$(id -ru)}" 2>/dev/null || true)
    fi
    if [[ "$invoker_user" == "$TARGET_USER" ]]; then
        echo "error: --hm-switch is for re-running HM as ANOTHER user." >&2
        echo "       To switch your own HM, just run:" >&2
        echo "         home-manager switch --flake $flake_root#'$hm_id'" >&2
        exit 2
    fi

    # 4. Confirm the HM config exists in this flake before touching
    # anything. Fast eval (no --refresh) — reading just the type is
    # enough to surface a missing entry as an evaluation error.
    echo ">> verifying homeConfigurations.\"$hm_id\" exists in flake …"
    set +e
    nix "${NIX_EXTRA_OPTS[@]}" eval --impure --raw \
        "$flake_root#homeConfigurations.\"$hm_id\".activationPackage.outPath" \
        >/dev/null 2>&1
    local check_rc=$?
    set -e
    if (( check_rc != 0 )); then
        echo "error: homeConfigurations.\"$hm_id\" not found in this flake." >&2
        echo "       expected entry in flake.nix outputs.homeConfigurations" >&2
        echo "       check available HM configs with:" >&2
        echo "         nix flake show $flake_root --allow-import-from-derivation 2>/dev/null \\" >&2
        echo "           | grep -A1 homeConfigurations" >&2
        exit 3
    fi

    # 5. Enable linger so user-bus + systemd --user persist even
    # without an active session. Idempotent: running on an already-
    # lingering user returns 0 immediately.
    echo ">> loginctl enable-linger $TARGET_USER"
    loginctl enable-linger "$TARGET_USER"

    # Wait for /run/user/<uid> to materialise. systemd-logind creates
    # it asynchronously after enable-linger; a fresh enable-linger on
    # a never-logged-in user takes ~100-500ms.
    local runtime_dir="/run/user/${target_uid}"
    local waited=0
    while [[ ! -d "$runtime_dir" ]]; do
        if (( waited >= 10 )); then
            echo "error: $runtime_dir did not appear within 10s after enable-linger." >&2
            echo "       check: systemctl status systemd-logind, journalctl -u systemd-logind" >&2
            exit 3
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo ">> $runtime_dir is ready (waited ${waited}s)"

    # 6. Build the activation package. We do this BEFORE switching
    # to the target user so build output and any errors stream to
    # the invoker's terminal in their normal locale, and so the
    # build runs as root (which has the nix-daemon socket
    # permissions and the substituter trust to fetch from any
    # configured cache without surprises).
    echo ">> nix build homeConfigurations.\"$hm_id\".activationPackage …"
    local activate_pkg
    set +e
    activate_pkg=$(nix "${NIX_EXTRA_OPTS[@]}" build --no-link --print-out-paths \
        "$flake_root#homeConfigurations.\"$hm_id\".activationPackage")
    local build_rc=$?
    set -e
    if (( build_rc != 0 )) || [[ -z "$activate_pkg" ]]; then
        echo "error: nix build failed (exit $build_rc)." >&2
        echo "       see stderr above for details." >&2
        exit 3
    fi
    if [[ ! -x "$activate_pkg/activate" ]]; then
        echo "error: activation package $activate_pkg has no executable activate script." >&2
        exit 3
    fi
    echo ">> built: $activate_pkg"

    # 7. Run activation as the target user. `runuser -l` sets a
    # proper login shell with HOME/USER/LOGNAME/XDG_* derived from
    # /etc/passwd. We additionally export XDG_RUNTIME_DIR and
    # DBUS_SESSION_BUS_ADDRESS so HM's `systemctl --user
    # daemon-reload` and unit start/stop work correctly. Without
    # these the activation prints "Failed to connect to bus" warnings
    # and leaves user units stale.
    echo
    echo ">> running $activate_pkg/activate as $TARGET_USER …"
    set +e
    runuser -l "$TARGET_USER" -c \
        "export XDG_RUNTIME_DIR='$runtime_dir' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus'; '$activate_pkg/activate'"
    local activate_rc=$?
    set -e
    if (( activate_rc != 0 )); then
        echo
        echo "error: home-manager activation for $TARGET_USER failed (exit $activate_rc)." >&2
        echo "       common causes:" >&2
        echo "         - existing non-symlink ~/.config/<thing> blocking HM (rm + retry)." >&2
        echo "         - per-user systemd-user not running (try logging $TARGET_USER" >&2
        echo "           in once on a tty to bootstrap, then re-run)." >&2
        exit 4
    fi
    echo
    echo ">> ✓ home-manager activation for $TARGET_USER succeeded."
    echo "    profile: $target_home/.local/state/nix/profiles/home-manager"
}

# ── dispatch ──────────────────────────────────────────────────────
case "$MODE" in
    mount)       do_mount ;;
    unmount)     do_unmount ;;
    partition)   do_partition ;;
    install)     do_install ;;
    install-hm)  do_install_hm ;;
    audio-discover) do_audio_discover ;;
    hm-switch)   do_hm_switch ;;
esac
