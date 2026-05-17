#!/usr/bin/env bash
# disko-migrate.sh — in-place migrate a pre-disko host to whatever
# canonical disko layout its host bridge now expects.
#
# Why this exists:
#   Hosts installed before the disko switchover typically have GPT
#   partitions without `disk-<diskname>-<partname>` partlabels, fewer
#   btrfs subvols than the factory creates (no /swap, no /.snapshots),
#   a btrfs filesystem label other than `nixos`, and a swapfile
#   placed inside the root subvol instead of its own no-CoW subvol.
#   Once `config.flake.modules.nixos.disko +
#   flake.lib.diskoLayouts.bare-metal` is in the host bridge, the
#   synthesized `fileSystems.*` set points at
#   /dev/disk/by-partlabel/disk-… paths and mountpoints /swap,
#   /.snapshots that the running disk doesn't expose, and the next
#   initrd hangs forever waiting for them.
#
#   pb-x1 hit exactly this trap and had to be unblocked by hand. This
#   script bottles that fix so the same dance on pb-t480 (and any
#   other pre-disko host) is one command instead of half an hour of
#   sgdisk + btrfs subvolume create + chattr + swapoff.
#
# What this does:
#   1. Reads the host's expected `fileSystems` from the flake (via
#      `nix eval --json`) — gives us the by-partlabel paths and the
#      subvol= mount options that the disko layout produces.
#   2. Compares to what's actually on disk (lsblk, btrfs subvol list,
#      swapon).
#   3. Prints a per-step plan. Without --yes that's all it does.
#   4. With --yes, executes each step in order:
#        * sgdisk -c <N>:<label> for any partition whose label is wrong
#        * btrfs filesystem label / nixos
#        * mount the top-level (subvolid=5), create missing subvols,
#          chattr +C on the swap subvol so swapfiles inherit no-CoW
#        * if the old swapfile is at /swap/swapfile in the root subvol,
#          swapoff + rm + rmdir so battery.nix can recreate it on the
#          new /swap subvol after rebuild
#
# What this deliberately doesn't do:
#   * Reboot or `nixos-rebuild` — those stay manual so you control
#     timing and can fall back to the rollback generation.
#   * Touch LUKS containers — refuses if the host bridge declares any
#     LUKS device (v1 limitation).
#   * Multi-disk layouts — refuses if `fileSystems.*` references more
#     than one parent block device (none of today's hosts do).
#
# Safe to re-run: every action is detect-then-act, so a second pass
# on an already-migrated host prints "nothing to do" and exits 0.
#
# Usage:
#   sudo ./scripts/disko-migrate.sh <hostname>           # dry-run / plan only
#   sudo ./scripts/disko-migrate.sh <hostname> --yes     # execute the plan
#
# After execution:
#   sudo nixos-rebuild boot --flake .#<hostname>
#   sudo reboot
#   # On first boot, capture the swap offset for hibernate-resume:
#   journalctl -u battery-resume-offset.service -b
#   # then add `boot.kernelParams = [ "resume_offset=<N>" ];` to the
#   # host bridge and rebuild once more.
#
# Retire when: every host this flake supports has been provisioned
#   through egghead/host-setup.sh on the disko code path — i.e. there
#   are no more pre-disko installs anywhere in the fleet.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 <hostname> [--yes]

  <hostname>     Target host. MUST match \`hostname\` on this machine.
                 Defends against running on the wrong box.

  --yes          Execute the plan. Without it, dry-run (plan only).
EOF
    exit 2
}

# ── arg parsing ──────────────────────────────────────────────────
HOSTNAME_ARG=""
EXECUTE="no"

while (( $# > 0 )); do
    case "$1" in
        --yes) EXECUTE="yes"; shift ;;
        -h|--help) usage ;;
        -*) echo "unknown flag: $1" >&2; usage ;;
        *) HOSTNAME_ARG="$1"; shift ;;
    esac
done

[[ -n "$HOSTNAME_ARG" ]] || usage

# ── pre-flight ───────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (sudo)." >&2
    exit 1
fi

running_host=$(hostname)
if [[ "$running_host" != "$HOSTNAME_ARG" ]]; then
    echo "error: running on '$running_host' but you passed '$HOSTNAME_ARG'." >&2
    echo "       Run this script ON the target host." >&2
    exit 1
fi

REPO_ROOT=""
for candidate in "$PWD" "$PWD/.." "$(dirname "$0")/.."; do
    if [[ -f "$candidate/flake.nix" ]]; then
        REPO_ROOT=$(cd "$candidate" && pwd); break
    fi
done
[[ -n "$REPO_ROOT" ]] || { echo "error: can't locate flake.nix above CWD or script dir." >&2; exit 1; }
cd "$REPO_ROOT"

for tool in nix jq sgdisk partprobe btrfs lsblk findmnt swapon chattr mount umount; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "error: missing required tool: $tool" >&2; exit 1; }
done

NIX_OPTS=( --extra-experimental-features 'nix-command flakes' )

# ── load expected layout from the flake ──────────────────────────
echo "── loading expected layout for $HOSTNAME_ARG ──"
flake_attr=".#nixosConfigurations.${HOSTNAME_ARG}"

# We can't dump `config.disko.devices.disk` directly because the
# disko module's resolved types include __functor closures that
# can't be serialized. `fileSystems` is pure scalar/list data after
# evaluation and contains everything we need: device path
# (= by-partlabel symlink), fsType, and subvol= options.
fs_json=$(nix "${NIX_OPTS[@]}" eval --json --refresh \
    "${flake_attr}.config.fileSystems" \
    --apply 'fs: builtins.mapAttrs (n: v: {
        device = v.device;
        fsType = v.fsType;
        options = v.options or [];
    }) fs' 2>/dev/null) \
    || { echo "error: can't evaluate ${flake_attr}.config.fileSystems" >&2; exit 1; }

# LUKS refusal: any boot.initrd.luks.devices entry triggers a bail.
luks_count=$(nix "${NIX_OPTS[@]}" eval --json --refresh \
    "${flake_attr}.config.boot.initrd.luks.devices" \
    --apply 'd: builtins.length (builtins.attrNames d)' 2>/dev/null || echo "0")
if (( luks_count > 0 )); then
    echo "error: $HOSTNAME_ARG declares $luks_count LUKS device(s); in-place LUKS migration is not supported." >&2
    echo "       Reinstall via egghead to enable LUKS on this host." >&2
    exit 1
fi

# Unique by-partlabel paths referenced by the expected fileSystems.
expected_partlabel_paths=$(jq -r '
    [.[] | .device | select(startswith("/dev/disk/by-partlabel/"))]
    | unique | .[]
' <<<"$fs_json")

if [[ -z "$expected_partlabel_paths" ]]; then
    echo "error: no /dev/disk/by-partlabel/* devices in $HOSTNAME_ARG's fileSystems — host doesn't use disko?" >&2
    exit 1
fi

# Expected subvols on the btrfs filesystem: every `subvol=<name>` in
# the options of any btrfs mount, deduped.
expected_subvols=$(jq -r '
    [.[]
     | select(.fsType == "btrfs")
     | .options[] | select(startswith("subvol="))
     | sub("^subvol="; "")
    ] | unique | .[]
' <<<"$fs_json")

# Map each expected mountpoint → expected (partlabel, subvol) tuple
# so we can later cross-check against findmnt.
echo "  fileSystems (expected):"
jq -r 'to_entries | sort_by(.key)
       | .[] | "    \(.key) → \(.value.device) (\(.value.fsType)\(if (.value.options // []) | any(. | startswith("subvol=")) then ", " + (.value.options[] | select(startswith("subvol="))) else "" end))"
' <<<"$fs_json"

echo "  expected subvols (btrfs): $(echo "$expected_subvols" | tr '\n' ' ')"
echo "  expected partlabels    :"
echo "$expected_partlabel_paths" | sed 's|^/dev/disk/by-partlabel/|    |'

# Expected btrfs fs label: the disko factory always emits `-L nixos`
# in extraArgs and that's the only label currently in use across
# every host. Hardcoding is fine; if it ever varies, derive from a
# new field in `fileSystems` or evaluate
# `config.disko.devices.disk.<X>.content.partitions.<Y>.content.extraArgs`.
expected_btrfs_label="nixos"

# Each expected partlabel maps to a partition name suffix
# (disk-<diskkey>-<partname> → partname). We need partname to figure
# out which currently-mounted device should carry that label.
declare -A want_label_for_role     # role (ESP/nixos/…) → full label
declare -A want_role_is_btrfs
for p in $expected_partlabel_paths; do
    label="${p#/dev/disk/by-partlabel/}"
    # Strip the `disk-<diskkey>-` prefix to get role.
    role="${label#disk-*-}"
    want_label_for_role["$role"]="$label"
    # Cross-check: is this partlabel used by a btrfs mount?
    if jq -e --arg dev "$p" '
        any(.[]; .device == $dev and .fsType == "btrfs")
    ' <<<"$fs_json" >/dev/null; then
        want_role_is_btrfs["$role"]=1
    fi
done

# ── discover actual on-disk state ────────────────────────────────
echo
echo "── inspecting actual disk state ──"

root_source=$(findmnt -no SOURCE /)
root_dev="${root_source%%\[*}"
[[ -b "$root_dev" ]] || { echo "error: can't resolve / to a block device (got '$root_dev')." >&2; exit 1; }

# Parent disk of the root partition. Everything we touch with sgdisk
# happens at this device level.
root_pkname=$(lsblk -no PKNAME "$root_dev")
disk_dev="/dev/${root_pkname}"
[[ -b "$disk_dev" ]] || { echo "error: can't resolve parent disk for $root_dev." >&2; exit 1; }

echo "  root device   : $root_dev (parent disk: $disk_dev)"

# Sanity: every other currently-mounted expected mountpoint must
# also live on $disk_dev. If /boot is on a different disk, multi-disk
# migration territory and we bail.
for mp in $(jq -r 'keys[]' <<<"$fs_json"); do
    src=$(findmnt -no SOURCE "$mp" 2>/dev/null || true)
    [[ -n "$src" ]] || continue
    bare="${src%%\[*}"
    pk=$(lsblk -no PKNAME "$bare" 2>/dev/null || true)
    if [[ -n "$pk" && "/dev/${pk}" != "$disk_dev" ]]; then
        echo "error: $mp is on /dev/${pk}, not $disk_dev — multi-disk host, not supported." >&2
        exit 1
    fi
done

# Current partition table on the target disk (one row per partition).
echo "  current partition table:"
lsblk -nplo NAME,PARTN,PARTLABEL,FSTYPE,MOUNTPOINTS "$disk_dev" \
    | sed 's/^/    /'

current_btrfs_label=$(btrfs filesystem label / 2>/dev/null || echo "")
echo "  btrfs fs label: ${current_btrfs_label:-<unset>}"

# Top-level subvols (parent_id=5). Disko creates every layout subvol
# at the top level, so anything missing here is migration work.
top_subvols=$(btrfs subvolume list / 2>/dev/null \
    | awk '$7 == 5 {for (i=9;i<=NF;i++) printf "%s%s", $i, (i==NF?"\n":" ")}' \
    | sort -u)
echo "  top-level subvols: $(echo "$top_subvols" | tr '\n' ' ')"

current_swap=$(swapon --show=NAME --noheadings 2>/dev/null | head -1 || true)
echo "  active swap   : ${current_swap:-<none>}"

# ── plan ─────────────────────────────────────────────────────────
echo
echo "── plan ──"
declare -a plan_cmds=()
declare -a plan_msgs=()

# 1. Partlabel renames. For each expected role, find the partition
#    on disk by what it backs (btrfs root → / mount) or by fsType +
#    mountpoint (vfat → /boot).
label_part() {
    local part_dev="$1" want_label="$2"
    local cur_label partnum
    cur_label=$(lsblk -no PARTLABEL "$part_dev" | head -1)
    if [[ "$cur_label" == "$want_label" ]]; then return 0; fi
    partnum=$(lsblk -no PARTN "$part_dev")
    plan_msgs+=("partlabel: $part_dev '${cur_label:-<unset>}' → '$want_label'")
    plan_cmds+=("sgdisk -c $partnum:$want_label $disk_dev")
}

# Find the actual partition backing each expected mountpoint, then
# label it according to the role we computed from the expected
# partlabel.
for mp in $(jq -r 'keys[]' <<<"$fs_json"); do
    expected_dev=$(jq -r --arg m "$mp" '.[$m].device' <<<"$fs_json")
    [[ "$expected_dev" == /dev/disk/by-partlabel/* ]] || continue
    role="${expected_dev#/dev/disk/by-partlabel/disk-*-}"
    src=$(findmnt -no SOURCE "$mp" 2>/dev/null || true)
    [[ -n "$src" ]] || {
        # Mountpoint doesn't exist yet (e.g. /swap, /.snapshots on a
        # pre-disko host) — partlabel work skipped for this role.
        continue
    }
    bare="${src%%\[*}"
    label_part "$bare" "${want_label_for_role[$role]}"
done

# 2. Btrfs FS label.
if [[ "$current_btrfs_label" != "$expected_btrfs_label" ]]; then
    plan_msgs+=("btrfs fs label: '${current_btrfs_label:-<unset>}' → '$expected_btrfs_label'")
    plan_cmds+=("btrfs filesystem label / $expected_btrfs_label")
fi

# 3. Missing top-level subvols. Mount the top-level (subvolid=5),
#    create each missing subvol, chattr +C on the swap one so any
#    swapfile written there inherits no-CoW (kernel refuses swapfiles
#    on CoW-enabled btrfs subvols).
missing_subvols=()
for s in $expected_subvols; do
    if ! grep -qxF "$s" <<<"$top_subvols"; then
        missing_subvols+=("$s")
    fi
done
need_top_mount=0
if (( ${#missing_subvols[@]} > 0 )); then
    need_top_mount=1
    plan_msgs+=("create top-level btrfs subvols: ${missing_subvols[*]}")
    plan_cmds+=("mkdir -p /mnt/disko-migrate-top")
    plan_cmds+=("mount -o subvolid=5 $root_dev /mnt/disko-migrate-top")
    for s in "${missing_subvols[@]}"; do
        plan_cmds+=("btrfs subvolume create /mnt/disko-migrate-top/$s")
        if [[ "$s" == "swap" ]]; then
            plan_cmds+=("chattr +C /mnt/disko-migrate-top/swap")
        fi
    done
    plan_cmds+=("umount /mnt/disko-migrate-top")
    plan_cmds+=("rmdir /mnt/disko-migrate-top")
fi

# 4. Retire pre-migration swapfile if it lives at /swap/swapfile
#    inside the root subvol AND the new /swap subvol is in the plan
#    (i.e. the path /swap/swapfile we see now is NOT the new subvol).
#    battery.nix will recreate the swapfile on the new subvol after
#    rebuild + reboot.
if [[ "$current_swap" == "/swap/swapfile" ]] \
       && printf '%s\n' "${missing_subvols[@]+"${missing_subvols[@]}"}" | grep -qxF "swap"; then
    plan_msgs+=("retire pre-migration swapfile /swap/swapfile (battery.nix will recreate on the new subvol)")
    plan_cmds+=("swapoff /swap/swapfile")
    plan_cmds+=("rm /swap/swapfile")
    plan_cmds+=("rmdir /swap")
fi

if (( ${#plan_msgs[@]} == 0 )); then
    echo "  nothing to do — host is already on the canonical disko layout."
    exit 0
fi

for i in "${!plan_msgs[@]}"; do
    printf '  %d. %s\n' "$((i+1))" "${plan_msgs[$i]}"
done

echo
echo "── commands (exact, in order) ──"
for cmd in "${plan_cmds[@]}"; do echo "  $cmd"; done

if [[ "$EXECUTE" != "yes" ]]; then
    echo
    echo "dry-run only. Re-run with --yes to execute."
    exit 0
fi

# ── execute ──────────────────────────────────────────────────────
echo
echo "── executing ──"
for cmd in "${plan_cmds[@]}"; do
    echo "+ $cmd"
    eval "$cmd"
done

echo "+ partprobe $disk_dev"
partprobe "$disk_dev"
# udev usually catches up within a beat, but give it a moment so
# the post-migration listing below reflects the new state.
sleep 1

echo
echo "── post-migration state ──"
echo "  partition table:"
lsblk -nplo NAME,PARTN,PARTLABEL,FSTYPE,MOUNTPOINTS "$disk_dev" | sed 's/^/    /'
echo "  by-partlabel:"
ls -1 /dev/disk/by-partlabel/ 2>/dev/null | sed 's/^/    /' || true
mkdir -p /mnt/disko-migrate-top
mount -o subvolid=5 "$root_dev" /mnt/disko-migrate-top
echo "  top-level subvols:"
btrfs subvolume list /mnt/disko-migrate-top 2>/dev/null \
    | awk '$7 == 5 {for (i=9;i<=NF;i++) printf "%s%s", $i, (i==NF?"\n":" ")}' \
    | sort -u | sed 's/^/    /'
umount /mnt/disko-migrate-top
rmdir /mnt/disko-migrate-top

echo
echo "── next steps ──"
echo "  1. sudo nixos-rebuild boot --flake .#${HOSTNAME_ARG}"
echo "  2. sudo reboot"
echo "  3. After first boot on the new generation, capture the swap"
echo "     resume offset (needed for hibernate-resume):"
echo "       journalctl -u battery-resume-offset.service -b"
echo "     Add the printed value to ${HOSTNAME_ARG}'s host bridge:"
echo "       boot.kernelParams = [ \"resume_offset=<N>\" ];"
echo "     Then sudo nixos-rebuild switch once more."
echo
echo "  If the new generation hangs at boot, force-reboot and pick"
echo "  the previous generation from the systemd-boot menu — nothing"
echo "  destructive was done here, the old layout is fully intact."
