#!/usr/bin/env bash
# mount-host.sh — bring a target disk's partitions back under /mnt
# (default), or partition+format+mount a fresh disk from scratch
# (--partition mode).
#
# Why this exists:
#   Re-entering a partially-installed system from the NixOS USB takes
#   six commands of muscle memory (mount root subvol, mkdir
#   boot/home/nix, mount each subvol, mount ESP). Easy to typo and
#   easy to forget --options. Mistakes here either silently install
#   the bootloader to the wrong place (entries land on btrfs root,
#   not the ESP) or, in --partition mode, obliterate the wrong disk.
#   Encode the layout from docs/runbooks/new-host-partitioning.md
#   into one auditable shell script.
#
# Usage:
#   sudo ./scripts/mount-host.sh /dev/nvme0n1                # mount-only (default)
#   sudo ./scripts/mount-host.sh /dev/nvme0n1 --partition    # destructive: wipe + format + mount
#   sudo ./scripts/mount-host.sh --help
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
#   - Refuses to run as non-root (mount/mkfs/wipefs need it).
#   - Refuses --partition without an interactive confirm prompt that
#     echoes back the disk identity (model + size + serial via lsblk)
#     and demands the literal word YES (uppercase).
#   - Mount-only mode is idempotent: if /mnt is already mounted with
#     the right device, it just verifies the rest and exits 0.
#
# Retire when: you replace this with a disko-based declarative
#   partitioning module and ditch manual mount sequences entirely.

set -euo pipefail

# ── arg parsing ───────────────────────────────────────────────────
DISK=""
PARTITION_MODE=0
SHOW_HELP=0

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        SHOW_HELP=1; shift ;;
        --partition)      PARTITION_MODE=1; shift ;;
        --)               shift; break ;;
        -*)
            echo "error: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            if [[ -z "$DISK" ]]; then
                DISK="$1"; shift
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

if [[ -z "$DISK" ]]; then
    echo "error: missing disk argument" >&2
    echo "usage: $0 <disk> [--partition]" >&2
    echo "       $0 --help" >&2
    exit 2
fi

# ── preconditions ─────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "error: must run as root (need mount / mkfs / wipefs)" >&2
    exit 2
fi

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

if (( PARTITION_MODE )); then
    require_tool wipefs
    require_tool sgdisk
    require_tool parted
    require_tool mkfs.fat
    require_tool mkfs.btrfs
    require_tool btrfs
fi

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
  7. Mount everything under /mnt as if for nixos-install.

Anything currently on $DISK will be lost beyond recovery.

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

    # Fall through to mount-only logic to actually mount everything
    # in the canonical order.
    do_mount
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
    echo "next steps (in /mnt or wherever your flake checkout lives):"
    echo "  nixos-generate-config --root /mnt --show-hardware-config \\"
    echo "    > /mnt/<repo>/hosts/<hostname>/hardware-configuration.nix"
    echo "  cd /mnt/<repo> && git add hosts/<hostname>/hardware-configuration.nix"
    echo "  nixos-install --root /mnt --flake .#<hostname>"
}

# ── dispatch ──────────────────────────────────────────────────────
if (( PARTITION_MODE )); then
    do_partition
else
    do_mount
fi
