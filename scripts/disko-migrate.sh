#!/usr/bin/env bash
# disko-migrate.sh — in-place migrate a pre-disko host to whatever
# canonical disko layout its host bridge now expects.
#
# Why this exists:
#   Hosts installed before the disko switchover typically have GPT
#   partitions without `disk-<diskname>-<partname>` partlabels, fewer
#   btrfs subvols than the factory creates (no /.snapshots), and a
#   btrfs filesystem label other than `nixos`. The current factory
#   also wants a dedicated `disk-main-swap` GPT partition at the end
#   of the disk (type 8200) so hibernate-resume works with no per-host
#   `resume_offset` capture — that partition is absent on every
#   pre-disko install. Once `config.flake.modules.nixos.disko +
#   flake.lib.diskoLayouts.bare-metal` is in the host bridge, the
#   synthesized `fileSystems.*` / `swapDevices` set points at
#   /dev/disk/by-partlabel/disk-… paths that the running disk doesn't
#   expose, and the next initrd hangs forever waiting for them.
#
#   pb-x1 hit exactly this trap and had to be unblocked by hand. This
#   script bottles that fix so the same dance on pb-t480 (and any
#   other pre-disko host) is one command instead of half an hour of
#   sgdisk + btrfs subvolume create + filesystem resize + mkswap.
#
# What this does:
#   1. Reads the host's expected `fileSystems`, `swapDevices` and the
#      disko `devices.disk.main` spec from the flake (via
#      `nix eval --json`) — gives us the by-partlabel paths, the
#      subvol= mount options, and the swap partition's target size.
#   2. Compares to what's actually on disk (lsblk, btrfs subvol list,
#      swapon, partlabel ls).
#   3. Prints a per-step plan. Without --yes that's all it does.
#   4. With --yes, executes each step in order:
#        * sgdisk -c <N>:<label> for any partition whose label is wrong
#        * btrfs filesystem label / nixos
#        * mount the top-level (subvolid=5), create missing subvols
#        * if the host expects a swap partition that doesn't exist:
#          - operator must retype the target disk's MODEL and SIZE
#            (same guard as `host-setup.sh --install`)
#          - swapoff any active swap on the target disk
#          - shrink btrfs to (current_size - swap_size - 256MiB)
#          - sgdisk delete + recreate nixos partition smaller
#          - sgdisk create swap partition at end (type 8200, label
#            disk-main-swap)
#          - partprobe, mkswap on the new partition
#        * retire any leftover btrfs swapfile (/swap/swapfile or
#          /.swapvol/swapfile from the pre-partition swap layout)
#
# What this deliberately doesn't do:
#   * Reboot or `nixos-rebuild` — those stay manual so you control
#     timing and can fall back to the rollback generation.
#   * Touch LUKS containers — refuses if the host bridge declares any
#     LUKS device (v1 limitation; LUKS reshape is genuinely scary).
#   * Multi-disk layouts — refuses if `fileSystems.*` references more
#     than one parent block device (none of today's hosts do).
#   * Migrate a disk where the partition expected to shrink isn't
#     last — refuses with a clear message if there's anything after
#     the nixos partition.
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

for tool in nix jq sgdisk partprobe btrfs lsblk findmnt swapon mkswap mount umount; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "error: missing required tool: $tool" >&2; exit 1; }
done

NIX_OPTS=( --extra-experimental-features 'nix-command flakes' )

# ── load expected layout from the flake ──────────────────────────
echo "── loading expected layout for $HOSTNAME_ARG ──"
flake_attr=".#nixosConfigurations.${HOSTNAME_ARG}"

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

# Read disko's resolved partition spec so we know the expected swap
# size + type for this host. The fast path is `partitions` keyed by
# role name (BIOS/ESP/nixos/swap); each value carries `size` and
# `type` after disko's module evaluation.
parts_json=$(nix "${NIX_OPTS[@]}" eval --json --refresh \
    "${flake_attr}.config.disko.devices.disk.main" \
    --apply 'd: { device = d.device; partitions = builtins.mapAttrs (n: p: { size = p.size or null; type = p.type or null; }) d.content.partitions; }' \
    2>/dev/null) \
    || { echo "error: can't evaluate ${flake_attr}.config.disko.devices.disk.main" >&2; exit 1; }

disko_disk=$(jq -r '.device' <<<"$parts_json")
want_swap_size=$(jq -r '.partitions.swap.size // ""' <<<"$parts_json")  # e.g. "32G" or ""

# Unique by-partlabel paths referenced by the expected fileSystems
# AND swapDevices. We need both so the swap partlabel shows up in the
# expected set even though it doesn't carry a fileSystems mount.
expected_partlabel_paths=$(jq -r '
    [.[] | .device | select(startswith("/dev/disk/by-partlabel/"))]
    | unique | .[]
' <<<"$fs_json")

swap_json=$(nix "${NIX_OPTS[@]}" eval --json --refresh \
    "${flake_attr}.config.swapDevices" \
    --apply 'l: builtins.map (d: { device = d.device; }) l' 2>/dev/null || echo "[]")
swap_partlabel_paths=$(jq -r '.[] | .device | select(startswith("/dev/disk/by-partlabel/"))' <<<"$swap_json" || true)

expected_partlabel_paths=$(printf '%s\n%s\n' "$expected_partlabel_paths" "$swap_partlabel_paths" \
    | grep -v '^$' | sort -u)

if [[ -z "$expected_partlabel_paths" ]]; then
    echo "error: no /dev/disk/by-partlabel/* devices in $HOSTNAME_ARG's fileSystems/swapDevices — host doesn't use disko?" >&2
    exit 1
fi

# Expected subvols on the btrfs filesystem.
expected_subvols=$(jq -r '
    [.[]
     | select(.fsType == "btrfs")
     | .options[] | select(startswith("subvol="))
     | sub("^subvol="; "")
    ] | unique | .[]
' <<<"$fs_json")

echo "  fileSystems (expected):"
jq -r 'to_entries | sort_by(.key)
       | .[] | "    \(.key) → \(.value.device) (\(.value.fsType)\(if (.value.options // []) | any(. | startswith("subvol=")) then ", " + (.value.options[] | select(startswith("subvol="))) else "" end))"
' <<<"$fs_json"

echo "  swapDevices (expected):"
jq -r '.[]? | "    \(.device)"' <<<"$swap_json" | sort -u

echo "  expected subvols (btrfs): $(echo "$expected_subvols" | tr '\n' ' ')"
echo "  expected partlabels    :"
echo "$expected_partlabel_paths" | sed 's|^/dev/disk/by-partlabel/|    |'
echo "  disko target disk      : $disko_disk"
echo "  disko swap size        : ${want_swap_size:-<none>}"

expected_btrfs_label="nixos"

declare -A want_label_for_role
for p in $expected_partlabel_paths; do
    label="${p#/dev/disk/by-partlabel/}"
    role="${label#disk-*-}"
    want_label_for_role["$role"]="$label"
done

# ── discover actual on-disk state ────────────────────────────────
echo
echo "── inspecting actual disk state ──"

root_source=$(findmnt -no SOURCE /)
root_dev="${root_source%%\[*}"
[[ -b "$root_dev" ]] || { echo "error: can't resolve / to a block device (got '$root_dev')." >&2; exit 1; }

root_pkname=$(lsblk -no PKNAME "$root_dev")
disk_dev="/dev/${root_pkname}"
[[ -b "$disk_dev" ]] || { echo "error: can't resolve parent disk for $root_dev." >&2; exit 1; }

echo "  root device   : $root_dev (parent disk: $disk_dev)"

# Multi-disk refusal.
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

echo "  current partition table:"
lsblk -nplo NAME,PARTN,PARTLABEL,FSTYPE,MOUNTPOINTS "$disk_dev" \
    | sed 's/^/    /'

current_btrfs_label=$(btrfs filesystem label / 2>/dev/null || echo "")
echo "  btrfs fs label: ${current_btrfs_label:-<unset>}"

top_subvols=$(btrfs subvolume list / 2>/dev/null \
    | awk '$7 == 5 {for (i=9;i<=NF;i++) printf "%s%s", $i, (i==NF?"\n":" ")}' \
    | sort -u)
echo "  top-level subvols: $(echo "$top_subvols" | tr '\n' ' ')"

current_swap=$(swapon --show=NAME --noheadings 2>/dev/null || true)
echo "  active swap   : ${current_swap:-<none>}"

# Is there already a partition labeled disk-main-swap?
have_swap_partlabel="no"
if [[ -b "/dev/disk/by-partlabel/disk-main-swap" ]]; then
    have_swap_partlabel="yes"
fi

# ── plan ─────────────────────────────────────────────────────────
echo
echo "── plan ──"
declare -a plan_msgs=()
declare -a plan_cmds=()
# A parallel "interactive" marker. Most plan steps run as plain `eval`
# commands; the swap-reshape step needs a typed-back disk confirmation
# inline, so it's tagged with a sentinel that the executor matches.
declare -a plan_kind=()       # "cmd" | "reshape-swap"

# 1. Partlabel renames for partitions backing currently-mounted FSes.
label_part() {
    local part_dev="$1" want_label="$2"
    local cur_label partnum
    cur_label=$(lsblk -no PARTLABEL "$part_dev" | head -1)
    if [[ "$cur_label" == "$want_label" ]]; then return 0; fi
    partnum=$(lsblk -no PARTN "$part_dev")
    plan_msgs+=("partlabel: $part_dev '${cur_label:-<unset>}' → '$want_label'")
    plan_cmds+=("sgdisk -c $partnum:$want_label $disk_dev")
    plan_kind+=("cmd")
}

for mp in $(jq -r 'keys[]' <<<"$fs_json"); do
    expected_dev=$(jq -r --arg m "$mp" '.[$m].device' <<<"$fs_json")
    [[ "$expected_dev" == /dev/disk/by-partlabel/* ]] || continue
    role="${expected_dev#/dev/disk/by-partlabel/disk-*-}"
    src=$(findmnt -no SOURCE "$mp" 2>/dev/null || true)
    [[ -n "$src" ]] || continue
    bare="${src%%\[*}"
    label_part "$bare" "${want_label_for_role[$role]}"
done

# 2. Btrfs FS label.
if [[ "$current_btrfs_label" != "$expected_btrfs_label" ]]; then
    plan_msgs+=("btrfs fs label: '${current_btrfs_label:-<unset>}' → '$expected_btrfs_label'")
    plan_cmds+=("btrfs filesystem label / $expected_btrfs_label")
    plan_kind+=("cmd")
fi

# 3. Missing top-level subvols.
missing_subvols=()
for s in $expected_subvols; do
    if ! grep -qxF "$s" <<<"$top_subvols"; then
        missing_subvols+=("$s")
    fi
done
if (( ${#missing_subvols[@]} > 0 )); then
    plan_msgs+=("create top-level btrfs subvols: ${missing_subvols[*]}")
    plan_cmds+=("mkdir -p /mnt/disko-migrate-top")
    plan_kind+=("cmd")
    plan_msgs+=("(mount top-level)")
    plan_cmds+=("mount -o subvolid=5 $root_dev /mnt/disko-migrate-top")
    plan_kind+=("cmd")
    for s in "${missing_subvols[@]}"; do
        plan_msgs+=("  btrfs subvolume create $s")
        plan_cmds+=("btrfs subvolume create /mnt/disko-migrate-top/$s")
        plan_kind+=("cmd")
    done
    plan_msgs+=("(unmount top-level)")
    plan_cmds+=("umount /mnt/disko-migrate-top")
    plan_kind+=("cmd")
    plan_cmds+=("rmdir /mnt/disko-migrate-top")
    plan_kind+=("cmd")
fi

# 4. Swap partition reshape — only if the bridge wants a swap
# partition AND the disk doesn't already have one.
if [[ -n "$want_swap_size" && "$have_swap_partlabel" == "no" ]]; then
    # Verify: nixos partition must be last on disk (nothing after it
    # to relocate). sfdisk-style end-sector check.
    root_part_dev="$root_dev"
    root_partn=$(lsblk -no PARTN "$root_part_dev")
    last_partn=$(lsblk -nplo PARTN "$disk_dev" | grep -v '^$' | sort -n | tail -1)
    if [[ "$root_partn" != "$last_partn" ]]; then
        echo "error: root partition ($root_part_dev, partn $root_partn) is not the last on $disk_dev (last is partn $last_partn)." >&2
        echo "       Cannot reshape — there is something between root and end-of-disk." >&2
        exit 1
    fi

    plan_msgs+=("RESHAPE: shrink btrfs + nixos partition, add swap partition (size $want_swap_size) at end of $disk_dev")
    plan_cmds+=("__RESHAPE_SWAP__ $root_part_dev $root_partn $want_swap_size")
    plan_kind+=("reshape-swap")
fi

# 5. Retire any leftover pre-partition swapfile.
for sf in /swap/swapfile /.swapvol/swapfile; do
    if [[ -f "$sf" ]]; then
        plan_msgs+=("retire pre-migration swapfile $sf")
        if grep -qxF "$sf" <<<"$current_swap"; then
            plan_cmds+=("swapoff $sf")
            plan_kind+=("cmd")
        fi
        plan_cmds+=("rm -f $sf")
        plan_kind+=("cmd")
        # Don't rmdir /swap — battery.nix used to mount the /swap
        # subvol there; the subvol no longer exists in the new layout
        # but we don't aggressively delete subvols (that's destructive
        # in the wrong way). Leave any stray /swap dir for the operator.
    fi
done

if (( ${#plan_msgs[@]} == 0 )); then
    echo "  nothing to do — host is already on the canonical disko layout."
    exit 0
fi

for i in "${!plan_msgs[@]}"; do
    printf '  %d. %s\n' "$((i+1))" "${plan_msgs[$i]}"
done

echo
echo "── commands (exact, in order) ──"
for i in "${!plan_cmds[@]}"; do
    if [[ "${plan_kind[$i]}" == "reshape-swap" ]]; then
        # Decompose the marker for human readability.
        read -r _marker pdev partn ssize <<<"${plan_cmds[$i]}"
        echo "  # swap-partition reshape:"
        echo "  swapoff -a                                                  # if any swap is active"
        echo "  btrfs filesystem resize -<delta> /                          # shrink fs by $ssize + 256MiB margin"
        echo "  sgdisk -d $partn $disk_dev                                  # delete nixos partition"
        echo "  sgdisk -n 0:-${ssize}:0 -c 0:disk-main-swap -t 0:8200 $disk_dev"
        echo "  sgdisk -n 0:<old_start>:<swap_start-1> -c 0:disk-main-nixos -t 0:8300 $disk_dev"
        echo "  partprobe $disk_dev"
        echo "  mkswap /dev/disk/by-partlabel/disk-main-swap"
    else
        echo "  ${plan_cmds[$i]}"
    fi
done

if [[ "$EXECUTE" != "yes" ]]; then
    echo
    echo "dry-run only. Re-run with --yes to execute."
    exit 0
fi

# ── execute ──────────────────────────────────────────────────────
echo
echo "── executing ──"

# Helper used by the swap-reshape step.
reshape_swap() {
    local root_part_dev="$1" root_partn="$2" swap_size="$3"

    # Disk-confirmation guard, same UX as host-setup.sh's
    # guard_disk_safety: operator types disk MODEL and SIZE.
    local disk_model disk_size
    disk_model=$(lsblk -dno MODEL "$disk_dev" 2>/dev/null | sed 's/[[:space:]]*$//' || true)
    disk_size=$(lsblk -dno SIZE "$disk_dev" 2>/dev/null | sed 's/[[:space:]]*$//' || true)
    [[ -n "$disk_model" ]] || disk_model="(no MODEL string)"
    [[ -n "$disk_size" ]]  || disk_size="(unknown size)"

    echo
    echo "  ─── DESTRUCTIVE STEP: swap-partition reshape on $disk_dev ───"
    echo "  Target disk : $disk_dev"
    echo "  Model       : $disk_model"
    echo "  Size        : $disk_size"
    echo "  Action      : shrink btrfs, shrink nixos partition by $swap_size,"
    echo "                create swap partition at end."
    echo
    echo "  This rearranges partitions on a disk in active use. A wrong"
    echo "  answer here corrupts data. Type the disk's MODEL and SIZE"
    echo "  back to confirm (whitespace + case ignored)."
    echo

    local normalize='tr "[:upper:]" "[:lower:]" | tr -d "[:space:]"'
    local want_model_norm want_size_norm
    want_model_norm=$(printf '%s' "$disk_model" | eval "$normalize")
    want_size_norm=$(printf '%s' "$disk_size"  | eval "$normalize")

    local attempt got_model_norm got_size_norm
    for attempt in 1 2 3; do
        read -r -p "    MODEL: " typed_model
        read -r -p "    SIZE : " typed_size
        got_model_norm=$(printf '%s' "$typed_model" | eval "$normalize")
        got_size_norm=$(printf '%s' "$typed_size"   | eval "$normalize")
        if [[ "$got_model_norm" == "$want_model_norm" && "$got_size_norm" == "$want_size_norm" ]]; then
            break
        fi
        echo "    mismatch (attempt $attempt/3)" >&2
        if (( attempt == 3 )); then
            echo "error: aborting reshape." >&2
            exit 1
        fi
    done

    # Convert "32G" / "12G" / "500M" etc. to bytes for arithmetic +
    # for btrfs resize.
    local swap_bytes
    case "$swap_size" in
        *G|*g) swap_bytes=$(( ${swap_size%[Gg]} * 1024 * 1024 * 1024 )) ;;
        *M|*m) swap_bytes=$(( ${swap_size%[Mm]} * 1024 * 1024 )) ;;
        *)
            echo "error: cannot parse swap_size='$swap_size' (expected NG or NM)" >&2
            exit 1
            ;;
    esac
    local margin_bytes=$(( 256 * 1024 * 1024 ))
    local shrink_bytes=$(( swap_bytes + margin_bytes ))

    echo "  + swapoff -a (any active swap will be turned off first)"
    swapoff -a || true

    echo "  + btrfs filesystem resize -${shrink_bytes} /"
    btrfs filesystem resize "-${shrink_bytes}" /

    # Snapshot the old nixos partition's start sector before deletion;
    # we'll re-create it with the same start so existing FS data stays
    # at the same on-disk offsets.
    local old_start
    old_start=$(sgdisk -i "$root_partn" "$disk_dev" \
        | awk '/First sector:/ {print $3; exit}')
    [[ -n "$old_start" ]] || { echo "error: can't read old start sector." >&2; exit 1; }
    echo "  (old nixos partition first sector: $old_start)"

    echo "  + sgdisk -d $root_partn $disk_dev"
    sgdisk -d "$root_partn" "$disk_dev"

    # Create the swap partition first (at end of disk via negative
    # start). sgdisk picks the next free partition number when given 0.
    echo "  + sgdisk -n 0:-${swap_size}:0 -c 0:disk-main-swap -t 0:8200 $disk_dev"
    sgdisk -n "0:-${swap_size}:0" -c "0:disk-main-swap" -t "0:8200" "$disk_dev"

    # Find which partition number was just assigned to swap so we can
    # read back its first sector → that becomes (swap_start - 1) as
    # the new nixos partition's last sector.
    partprobe "$disk_dev"
    sleep 1
    local swap_partn
    swap_partn=$(sgdisk -p "$disk_dev" \
        | awk -v want="disk-main-swap" '$0 ~ want {print $1; exit}')
    [[ -n "$swap_partn" ]] || { echo "error: can't find newly-created swap partition number." >&2; exit 1; }
    local swap_start
    swap_start=$(sgdisk -i "$swap_partn" "$disk_dev" \
        | awk '/First sector:/ {print $3; exit}')
    [[ -n "$swap_start" ]] || { echo "error: can't read swap partition first sector." >&2; exit 1; }
    local nixos_end=$(( swap_start - 1 ))
    echo "  (swap first sector: $swap_start → new nixos last sector: $nixos_end)"

    echo "  + sgdisk -n $root_partn:$old_start:$nixos_end -c $root_partn:disk-main-nixos -t $root_partn:8300 $disk_dev"
    sgdisk -n "$root_partn:$old_start:$nixos_end" -c "$root_partn:disk-main-nixos" -t "$root_partn:8300" "$disk_dev"

    echo "  + partprobe $disk_dev"
    partprobe "$disk_dev"
    sleep 1

    echo "  + mkswap /dev/disk/by-partlabel/disk-main-swap"
    mkswap /dev/disk/by-partlabel/disk-main-swap
}

for i in "${!plan_cmds[@]}"; do
    if [[ "${plan_kind[$i]}" == "reshape-swap" ]]; then
        read -r _marker pdev partn ssize <<<"${plan_cmds[$i]}"
        reshape_swap "$pdev" "$partn" "$ssize"
    else
        echo "+ ${plan_cmds[$i]}"
        eval "${plan_cmds[$i]}"
    fi
done

# Final partprobe so the post-migration listing reflects the final
# state. (reshape_swap already calls partprobe, but harmless to run
# again, and required if only label changes happened.)
echo "+ partprobe $disk_dev"
partprobe "$disk_dev"
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
echo
echo "  Hibernate-resume works out of the box: disko's swap content"
echo "  type set boot.resumeDevice to /dev/disk/by-partlabel/disk-main-swap,"
echo "  which is a stable identifier — no resume_offset capture needed."
echo
echo "  If the new generation hangs at boot, force-reboot and pick"
echo "  the previous generation from the systemd-boot menu — the old"
echo "  layout is partially intact (partition table changed; FS data"
echo "  preserved within the smaller nixos partition; old kernel still"
echo "  references the old partlabel-less paths so it will fail too —"
echo "  use a NixOS live ISO with this flake to investigate)."
