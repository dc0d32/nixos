#!/usr/bin/env bash
# host-setup.sh — install-time setup for this flake's hosts.
#
# Modes (exactly one per invocation, picked by flag):
#
#   --install <h>  DESTRUCTIVE: wipe target disk, apply the host's
#                  disko layout, run nixos-install. The disk is read
#                  from `nixosConfigurations.<h>.config.disko.devices.
#                  disk.main.device` (defined in the host bridge via
#                  config.flake.lib.diskoLayouts.{bare-metal,vm}). A
#                  literal `--disk <path>` may override.
#                    After nixos-install succeeds, --install ALSO
#                  (unless overridden) regenerates
#                  hardware-configuration.nix via nixos-generate-
#                  config --no-filesystems, git-adds it, seeds ~/nixos
#                  for every HM-enabled user via `git clone https://
#                  github.com/dc0d32/nixos`, and chains --install-hm
#                  so each user's home-manager profile is bootstrapped
#                  before reboot. The primary user's clone gets the
#                  just-regenerated hardware-configuration.nix copied
#                  into its working tree so the first commit-and-push
#                  on the new host is a single step.
#                    Opt out of the chain steps with --no-regen-hwconfig
#                  / --no-clone-sources / --no-install-hm.
#                    --force-disk bypasses every guard_disk_safety check
#                  (live-ISO-source, min size, mounted partitions,
#                  typed-back confirmation). ONLY use for automated
#                  smoke tests; a typo destroys data.
#   --unmount      Recursively unmount everything under /mnt and
#                  remove the empty mountpoint dirs disko created.
#                  Idempotent.
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
#   Disk layout is declarative (flake-modules/disko.nix) but the
#   live-installer dance to apply it isn't: you still need to run the
#   right disko script, wait for it to mount /mnt, then nixos-install,
#   then HM bootstrap. Encoding the sequence here keeps "fresh
#   install" to one command:
#
#     sudo ./scripts/host-setup.sh --install <host>
#
#   and bakes in the AGENTS.md "git add or it doesn't count" rule.
#
# Usage:
#   sudo ./scripts/host-setup.sh --install pb-t480           # full install
#   sudo ./scripts/host-setup.sh --install pb-t480 \
#       --disk /dev/sda                                      # override disk
#   sudo ./scripts/host-setup.sh --install pb-t480 \
#       --no-clone-sources --no-install-hm                   # bare install
#   sudo ./scripts/host-setup.sh --unmount                   # umount /mnt tree
#   sudo ./scripts/host-setup.sh --install-hm                # bootstrap HM
#   ./scripts/host-setup.sh --audio-discover                 # print autoload
#   sudo ./scripts/host-setup.sh --hm-switch m               # HM switch for m
#   sudo ./scripts/host-setup.sh --help
#
# Disk layout:
#   Defined declaratively by flake-modules/disko.nix and instantiated
#   per host in flake-modules/hosts/<host>.nix via
#   config.flake.lib.diskoLayouts.bare-metal / .vm. See those files
#   for the actual partition + subvol layout. This script does not
#   encode partition geometry.
#
# Safety:
#   - Refuses to run as non-root (mount/mkfs/wipefs/nixos-install need it).
#   - --install runs guard_disk_safety BEFORE the destructive disko
#     script: refuses if the target disk is the live ISO's source,
#     is < 16 GiB, or has any currently-mounted partition. Final
#     confirmation requires the operator to retype the disk's MODEL
#     and SIZE (case + whitespace ignored) — far harder to fat-finger
#     than the old "type YES" prompt. Pass --force-disk to skip all
#     four checks (only for automated smoke tests; a typo destroys
#     data). The disko script itself is destructive and wipes the
#     partition table — there is no recovery once confirmation
#     passes.
#   - --unmount only walks /mnt and below; it does not touch anything
#     outside that subtree.
#
# Hibernate-resume:
#   Swap lives on its own GPT partition (provisioned by the disko
#   factory's `swapSize` arg). The disko swap content type sets
#   `boot.resumeDevice` to /dev/disk/by-partlabel/disk-main-swap
#   automatically — no `resume_offset=` to maintain, no first-boot
#   wart. Hosts that don't pass `swapSize` get no swap and can't
#   hibernate; that's the right answer for servers / VMs that don't
#   need it.
#
# Retire when: disko publishes a turnkey installer for this exact
#   "disko + nixos-install + per-user HM bootstrap + clone seeding"
#   workflow upstream, OR you build a NixOS image (nixos-anywhere /
#   nixos-generators) that bakes the install logic into the installer
#   ISO itself.
# === END HELP ===

set -Eeuo pipefail

# ── arg parsing ───────────────────────────────────────────────────
DISK=""
HOSTNAME=""
TARGET_USER=""
MODE=""        # one of: unmount | install | install-hm | audio-discover | hm-switch
SHOW_HELP=0

# Post-install chained steps. All default ON; opt out per invocation.
# Only consulted by --install mode; ignored by other modes.
INSTALL_HM_AUTO=1     # toggled by --no-install-hm
CLONE_SOURCES=1       # toggled by --no-clone-sources
REGEN_HWCONFIG=1      # toggled by --no-regen-hwconfig
FORCE_DISK=0          # toggled by --force-disk (skips guard_disk_safety checks)

# Repo URL used to seed each user's ~/nixos at install time. HTTPS so
# the clone works without per-user SSH credentials being deployed
# first; users who later want to push will need to either swap the
# remote to git@github.com:dc0d32/nixos.git or set up gh-cli auth /
# a credential helper. p's working tree gets the regenerated hwconfig
# pre-populated by the seeding step (see do_clone_sources), so the
# very first push from the new host is a single commit-and-push.
SEED_REPO_URL="https://github.com/dc0d32/nixos"

usage() {
    # Print everything from line 2 down to the END HELP sentinel.
    sed -n '2,/^# === END HELP ===$/p' "$0" \
        | sed '$d' \
        | sed 's/^# \{0,1\}//'
}

set_mode() {
    local new="$1"
    if [[ -n "$MODE" && "$MODE" != "$new" ]]; then
        echo "error: mode flags are mutually exclusive (--unmount/--install/--install-hm/--audio-discover/--hm-switch)" >&2
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
        --unmount|--umount)
            set_mode unmount
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
        --disk)
            shift
            if [[ $# -eq 0 || "$1" =~ ^- ]]; then
                echo "error: --disk requires a device path argument" >&2
                exit 2
            fi
            DISK="$1"
            shift
            ;;
        --install-hm)
            set_mode install-hm
            shift
            ;;
        --no-install-hm)
            # Opt out of the auto-chain in --install mode. Has no
            # effect on other modes.
            INSTALL_HM_AUTO=0
            shift
            ;;
        --no-clone-sources)
            # Opt out of seeding ~/nixos for each user in --install
            # mode. Has no effect on other modes.
            CLONE_SOURCES=0
            shift
            ;;
        --no-regen-hwconfig)
            # Opt out of regenerating hardware-configuration.nix
            # post-install. Has no effect on other modes.
            REGEN_HWCONFIG=0
            shift
            ;;
        --force-disk)
            # Skip every guard_disk_safety check (live-ISO source,
            # min size, mounted partitions, typed-back confirmation).
            # ONLY for automated smoke tests. A typo here destroys
            # data. See guard_disk_safety in this file.
            FORCE_DISK=1
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
            echo "error: unexpected positional arg: $1" >&2
            echo "       (use --disk <path> to override the host's disko-declared disk)" >&2
            exit 2
            ;;
    esac
done

if (( SHOW_HELP )); then
    usage
    exit 0
fi

if [[ -z "$MODE" ]]; then
    echo "error: no mode given." >&2
    echo "       see: $0 --help" >&2
    exit 2
fi

# Mode-specific arg validation.
case "$MODE" in
    install)
        # --disk is optional (default comes from disko spec)
        ;;
    unmount|install-hm|audio-discover|hm-switch)
        if [[ -n "$DISK" ]]; then
            echo "error: --$MODE does not take --disk" >&2
            exit 2
        fi
        ;;
esac

# ── preconditions ─────────────────────────────────────────────────
# audio-discover is read-only; everything else mutates root-owned state.
if [[ "$MODE" != "audio-discover" && "$EUID" -ne 0 ]]; then
    echo "error: --$MODE must run as root (need mount / nix store / nixos-install)" >&2
    exit 2
fi

# Required tools. lsblk + mount + umount + findmnt are coreutils/util-
# linux core; the rest depend on mode. Partition geometry tooling
# (wipefs/sgdisk/parted/mkfs.*) is no longer needed in this script —
# the disko-generated script in `config.system.build.diskoScript`
# pulls those in from the nix store at runtime.
require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: required tool not found: $1" >&2
        exit 2
    fi
}
require_tool lsblk
require_tool findmnt

case "$MODE" in
    unmount)
        require_tool mount
        require_tool umount
        ;;
    install)
        require_tool mount
        require_tool umount
        require_tool git
        require_tool nix
        require_tool nixos-install
        # TPM2 LUKS enrollment uses these. cryptsetup is always
        # available on a live ISO (initrd needs it); systemd-cryptenroll
        # ships as part of systemd. Both are required only when
        # EGGHEAD_LUKS_TPM=yes, but checking unconditionally keeps the
        # failure surface in one place at script start instead of
        # halfway through a destructive install.
        require_tool cryptsetup
        require_tool systemd-cryptenroll
        # nixos-generate-config is invoked only when REGEN_HWCONFIG=1;
        # check there rather than failing here.
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

# ── helper: parent block device for a given mount source ──────────
# Given e.g. "/dev/sda2" prints "/dev/sda"; given "/dev/loop0" prints
# "/dev/loop0" unchanged; given "" or a non-block source prints "".
# Used by guard_disk_safety to detect when the operator is about to
# wipe the device the live ISO booted from.
parent_block_device() {
    local src="$1"
    [[ -z "$src" || ! -b "$src" ]] && return 0
    local pk
    pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [[ -n "$pk" ]]; then
        printf "/dev/%s\n" "$pk"
    else
        # No parent → src is itself a whole-disk node (or a loop).
        printf "%s\n" "$src"
    fi
}

# ── helper: gather all parent block devices currently hosting the
# live installer environment ──────────────────────────────────────
# Returns a deduplicated list of /dev/* whole-disk paths. We check
# the obvious mountpoints (/, /nix/store, /iso, /run/initramfs/live)
# plus anything findmnt reports under /run/iso-style locations.
# A read-only nix store (/nix/.ro-store) backed by a squashfs on the
# ISO is what most modern installer ISOs use; we want to catch that.
live_iso_parents() {
    local seen=" "
    local mp src parent
    for mp in / /nix /nix/store /nix/.ro-store /iso /run/iso \
              /run/initramfs/live /run/installer; do
        src=$(findmnt -n -o SOURCE --target "$mp" 2>/dev/null | head -1)
        parent=$(parent_block_device "$src")
        if [[ -n "$parent" && "$seen" != *" $parent "* ]]; then
            seen+="$parent "
            printf "%s\n" "$parent"
        fi
    done
}

# ── pre-install disk safety ───────────────────────────────────────
# Fails fast (via abort_revert) when:
#   1. $DISK is one of the parent block devices currently hosting
#      the live installer environment (would wipe our own ISO/USB).
#   2. $DISK is smaller than MIN_DISK_BYTES (default 16 GiB) — too
#      small to install a usable system, almost always points at a
#      USB key the operator confused with the target.
#   3. Any partition on $DISK is currently mounted somewhere other
#      than /mnt — would silently destroy whatever is using it.
#   4. The operator fails the typed-back confirmation. The prompt
#      shows MODEL and SIZE; the operator must retype them (without
#      whitespace, case-insensitive) — much harder to fat-finger
#      than the old "YES" prompt.
# All four checks can be silenced with --force-disk for automated
# tests (egghead's --non-interactive smoke runs).
MIN_DISK_BYTES=$((16 * 1024 * 1024 * 1024))

guard_disk_safety() {
    local disk="$1"

    # 1. Live ISO source check.
    local iso
    while IFS= read -r iso; do
        [[ -z "$iso" ]] && continue
        if [[ "$iso" == "$disk" ]]; then
            echo "error: refusing to wipe $disk — it is the live installer source." >&2
            echo "       (something is mounted from $disk under /, /nix/store, or /iso)" >&2
            echo "       Use a different --disk, or pass --force-disk to override." >&2
            (( FORCE_DISK )) || abort_revert
            echo "warning: --force-disk supplied; ignoring live-ISO-source check." >&2
            break
        fi
    done < <(live_iso_parents)

    # 2. Minimum size.
    local size_bytes
    size_bytes=$(lsblk -bndo SIZE "$disk" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [[ -z "$size_bytes" ]] || (( size_bytes < MIN_DISK_BYTES )); then
        echo "error: $disk is ${size_bytes:-?} bytes; refusing to install on anything < $MIN_DISK_BYTES bytes (16 GiB)." >&2
        echo "       Probably wrong disk path. Pass --force-disk if you really mean it." >&2
        if ! (( FORCE_DISK )); then abort_revert; fi
        echo "warning: --force-disk supplied; ignoring small-disk check." >&2
    fi

    # 3. Already-mounted partition check. We don't allow ANY part of
    # the target disk to be currently mounted, even at /mnt — disko
    # is about to wipe the partition table, and mounted partitions
    # would either lose data or refuse to unmount.
    local mounted
    mounted=$(lsblk -nrpo NAME,MOUNTPOINT "$disk" 2>/dev/null \
        | awk '$2 != "" { print $1 " → " $2 }')
    if [[ -n "$mounted" ]]; then
        echo "error: refusing to wipe $disk — partitions are currently mounted:" >&2
        echo "$mounted" >&2
        echo "       Unmount them (sudo $0 --unmount) and retry." >&2
        if ! (( FORCE_DISK )); then abort_revert; fi
        echo "warning: --force-disk supplied; ignoring mounted-partition check." >&2
    fi

    # 4. Typed-back confirmation. Skipped under --force-disk so CI /
    # non-interactive smoke runs don't have to script a stdin reply.
    if (( FORCE_DISK )); then
        echo ">> --force-disk: skipping YES confirmation."
        return 0
    fi
    prompt_disk_confirm "$disk"
}

# ── helper: destructive-wipe confirmation ─────────────────────────
# Shows the target's MODEL + SIZE so the operator can sanity-check
# the disk identity, then requires a literal "YES" to proceed.
# Anything else aborts. Case-sensitive on purpose — "yes" / "y" are
# the kinds of replies a flow-state operator gives by reflex.
prompt_disk_confirm() {
    local disk="$1"
    local model size got
    model=$(lsblk -ndo MODEL "$disk" 2>/dev/null | tr -d '\n' | awk '{$1=$1};1')
    size=$(lsblk -ndo SIZE "$disk" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$model" ]] && model="(no-model)"

    cat <<EOF

*** DESTRUCTIVE CONFIRMATION ***

About to wipe and re-partition:

  Disk : $disk
  Model: $model
  Size : $size

EOF
    read -r -p "Type YES (in uppercase) to wipe this disk, anything else aborts: " got
    if [[ "$got" != "YES" ]]; then
        echo "error: confirmation not 'YES'; aborting." >&2
        abort_revert
    fi
    echo ">> wipe confirmed."
}

# ── --unmount mode: release /mnt tree cleanly ─────────────────────
# Idempotent: missing mountpoints are fine. Only walks /mnt and below.
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
        # Walk submounts manually if any. Covers both the bare-metal
        # disko layout (boot/home/nix/swap/.snapshots) and the vm one
        # (just /boot). Order matters for non-recursive umount: deepest
        # first.
        local m
        for m in /mnt/boot /mnt/home /mnt/nix /mnt/swap /mnt/.snapshots; do
            if mountpoint -q "$m"; then
                echo ">> umount $m …"
                umount "$m"
            fi
        done
    fi

    # Remove empty mountpoint dirs that disko created. rmdir refuses
    # non-empty dirs, which is the desired safety.
    local d
    for d in /mnt/boot /mnt/home /mnt/nix /mnt/swap /mnt/.snapshots; do
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
    # 1. Locate flake root.
    local flake_root
    if ! flake_root=$(find_flake_root); then
        echo "error: no flake.nix found in cwd or any ancestor of either" >&2
        echo "       cwd or the script's own directory." >&2
        echo "       cd into your flake checkout and re-run." >&2
        exit 3
    fi
    echo ">> flake root: $flake_root"

    # 1a. Shred-on-exit for the LUKS passphrase tmpfs file, if egghead
    # handed one in. Set up the trap BEFORE anything destructive runs
    # so an abort partway through still scrubs the passphrase from
    # tmpfs. shred has no effect on tmpfs (it's RAM-backed and
    # overwrites are observable only by the kernel), but it's a no-op
    # warning at worst; the rm is the load-bearing step. We also clear
    # EGGHEAD_LUKS_PASSWORD_FILE from the env so any child process
    # spawned after this point can't resurrect the path.
    # Shred-on-exit for any tmpfs secret files egghead handed in.
    # Combined into a single trap because bash's `trap … EXIT`
    # replaces, doesn't append. Each file is optional (the operator
    # may not have used LUKS, or may not have enabled backups).
    _egghead_secrets_cleanup() {
        local f
        for f in \
            "${EGGHEAD_LUKS_PASSWORD_FILE:-}" \
            "${EGGHEAD_BACKUP_REPO_PASSWORD_FILE:-}" \
            "${EGGHEAD_SEED_USERS_FILE:-}"; do
            if [[ -n "$f" ]] && [[ -f "$f" ]]; then
                shred -u "$f" 2>/dev/null || rm -f "$f"
            fi
        done
    }
    if [[ -n "${EGGHEAD_LUKS_PASSWORD_FILE:-}${EGGHEAD_BACKUP_REPO_PASSWORD_FILE:-}${EGGHEAD_SEED_USERS_FILE:-}" ]]; then
        trap _egghead_secrets_cleanup EXIT
    fi

    # 2. Verify the host bridge file exists. This is also a sanity
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

    # 3. Regenerate hardware-configuration.nix from the live installer
    # kernel. --no-filesystems is critical: disko owns fileSystems.*
    # and swapDevices, and a generated `fileSystems."/"` entry would
    # collide with the one disko produces from the host's diskoLayouts
    # call. We also stay away from --root: that flag controls where
    # the generator WRITES, not where it inspects. We want the live
    # installer kernel's view of the hardware (lsmod / lspci / lsblk),
    # which is what bare invocation gives us.
    local hwcfg_backup="${hwcfg}.before-install"
    local had_prior=0
    if [[ -f "$hwcfg" ]]; then
        cp "$hwcfg" "$hwcfg_backup"
        had_prior=1
    fi

    cleanup_hwcfg_artifacts() {
        if [[ -f "$hwcfg_backup" ]]; then
            rm -f "$hwcfg_backup"
        fi
    }

    abort_revert() {
        echo "aborted."
        git -C "$flake_root" restore --staged \
            "hosts/$HOSTNAME/hardware-configuration.nix" 2>/dev/null || true
        if (( had_prior )); then
            cp "$hwcfg_backup" "$hwcfg"
        else
            rm -f "$hwcfg"
        fi
        cleanup_hwcfg_artifacts
        exit 1
    }

    if (( REGEN_HWCONFIG )); then
        require_tool nixos-generate-config
        require_tool diff
        echo ">> regenerating $hwcfg via nixos-generate-config --no-filesystems --show-hardware-config …"
        nixos-generate-config --no-filesystems --show-hardware-config > "$hwcfg"

        echo
        echo ">> diff of $hwcfg against previously-committed:"
        if (( had_prior )); then
            diff -u "$hwcfg_backup" "$hwcfg" || true
        else
            echo "  (no prior file existed; full content is new)"
        fi
        echo

        # git add. Flake builds only see git-tracked files
        # (AGENTS.md hard rule).
        echo ">> git add $hwcfg"
        git -C "$flake_root" add "hosts/$HOSTNAME/hardware-configuration.nix"

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
        echo
    else
        echo ">> skipping hardware-configuration.nix regeneration (--no-regen-hwconfig)."
    fi

    # 4. Resolve disk. Honour --disk override, otherwise read from
    # the host's disko spec. Eval is --refresh'd so any just-staged
    # hwconfig change is picked up; --impure lets the placeholder
    # hosts evaluate under NIXOS_ALLOW_PLACEHOLDER=1 (which the env
    # of `sudo` carries through to the child nix invocation).
    if [[ -z "$DISK" ]]; then
        echo ">> resolving disk via nix eval --refresh disko.devices.disk.main.device …"
        local nix_eval_rc
        set +e
        DISK=$(nix "${NIX_EXTRA_OPTS[@]}" "${NIX_SUBSTITUTER_OPTS[@]}" eval --refresh --impure --raw \
            "$flake_root#nixosConfigurations.$HOSTNAME.config.disko.devices.disk.main.device")
        nix_eval_rc=$?
        set -e
        if (( nix_eval_rc != 0 )) || [[ -z "$DISK" ]]; then
            echo "error: nix eval failed to resolve the host's disko disk device." >&2
            echo "       (looked for disko.devices.disk.main.device on $HOSTNAME)" >&2
            echo "       Pass --disk </dev/...> to override, or wire a" >&2
            echo "       diskoLayouts.* call into the host bridge." >&2
            abort_revert
        fi
        echo "  disk from disko spec: $DISK"
    else
        echo ">> using disk override from --disk flag: $DISK"
    fi

    if [[ ! -b "$DISK" ]]; then
        echo "error: $DISK is not a block device on the live installer." >&2
        abort_revert
    fi
    show_disk
    guard_disk_safety "$DISK"

    # 5. Refuse if anything under /mnt is currently mounted. The
    # disko script will mount its own layout at /mnt; pre-existing
    # mounts would either get hidden under the new ones (silent data
    # confusion) or cause disko to abort partway through.
    if mountpoint -q /mnt || findmnt -rno SOURCE | grep -qE "[[:space:]]/mnt(/|$)" 2>/dev/null; then
        echo "error: something is mounted at or under /mnt." >&2
        echo "       run: sudo $0 --unmount   first, or unmount manually." >&2
        findmnt -R /mnt >&2 || true
        abort_revert
    fi

    # 6. Build the disko script. config.system.build.diskoScript is
    # produced by disko's NixOS module from disko.devices, and is a
    # shell script that wipes + partitions + formats + mounts the
    # declared layout at /mnt. We build it explicitly (rather than
    # invoking `nix run github:nix-community/disko#disko-install`)
    # because:
    #   - the layout is already in our flake, so there's no need to
    #     re-resolve disko's own version from upstream
    #   - having the script path in hand lets the YES prompt show
    #     `--dry-run` or `ls -l` if the operator wants to inspect
    #   - same nix invocation gets the niri-cachix substituters,
    #     keeping behaviour consistent with nixos-install
    echo
    echo ">> building disko script for $HOSTNAME …"
    local disko_script
    set +e
    disko_script=$(nix "${NIX_EXTRA_OPTS[@]}" "${NIX_SUBSTITUTER_OPTS[@]}" build --refresh --impure \
        --no-link --print-out-paths \
        "$flake_root#nixosConfigurations.$HOSTNAME.config.system.build.diskoScript")
    local rc=$?
    set -e
    if (( rc != 0 )) || [[ -z "$disko_script" ]]; then
        echo "error: failed to build diskoScript (exit $rc)." >&2
        abort_revert
    fi
    echo "  disko script: $disko_script"

    # 7. Final summary. The destructive YES/MODEL+SIZE prompt
    # already ran inside guard_disk_safety (step 4.5). This block is
    # informational only — by the time we get here, the operator has
    # explicitly confirmed.
    cat <<EOF

>> proceeding with destructive install (confirmation passed earlier).

   Plan:
     1. Execute the host's disko script — wipes $DISK, writes a
        fresh partition table, creates filesystems, mounts /mnt.
     2. Run nixos-install --root /mnt --flake $flake_root#$HOSTNAME.
EOF
    if (( CLONE_SOURCES )); then
        echo "     3. Clone https://github.com/dc0d32/nixos into each HM user's ~/nixos."
    fi
    if (( INSTALL_HM_AUTO )); then
        echo "     4. Trigger home-manager bootstrap for each HM-enabled user."
    fi
    echo
    # 8. Execute disko. The script ends with everything mounted at
    # /mnt — / on the root subvol, /mnt/boot on the ESP, /mnt/nix,
    # /mnt/home, /mnt/swap, /mnt/.snapshots (bare-metal) or /mnt
    # + /mnt/boot (vm).
    echo
    echo ">> executing disko script …"
    "$disko_script"

    echo
    echo ">> disko complete; /mnt state:"
    findmnt -R /mnt || true
    echo

    # 8a. TPM2 enrollment (optional). When the wizard set LUKS_TPM=yes,
    # the LUKS container is already open at /dev/mapper/cryptroot and
    # the passphrase that disko used to format/open it sits in the
    # tmpfs key file referenced by EGGHEAD_LUKS_PASSWORD_FILE. Enroll
    # a TPM2 keyslot bound to PCR 7 so the disk auto-unlocks at boot.
    # The passphrase keyslot stays in place as a fallback for the case
    # where PCR 7 changes (Secure Boot toggled, firmware re-keyed,
    # etc.). Skip silently when not requested or when /dev/tpmrm0 is
    # absent — the installed system will keep using the passphrase
    # path the existing host bridge emits.
    if [[ "${EGGHEAD_LUKS_TPM:-no}" == "yes" ]] && \
       [[ -n "${EGGHEAD_LUKS_PASSWORD_FILE:-}" ]] && \
       [[ -f "$EGGHEAD_LUKS_PASSWORD_FILE" ]]; then
        if [[ ! -e /dev/tpmrm0 ]]; then
            echo "warn: EGGHEAD_LUKS_TPM=yes but /dev/tpmrm0 missing;" >&2
            echo "      skipping TPM2 enrollment (boot will prompt for passphrase)." >&2
        else
            # Surface SB state in the install log. PCR 7 seals against
            # whatever value SB has at enrollment time; the wizard
            # already warned the operator if SB is off. We re-log it
            # here so the install transcript records what was sealed.
            local sb_efivar="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
            local sb_state="unknown"
            if [[ -e "$sb_efivar" ]]; then
                case "$(od -An -t u1 "$sb_efivar" 2>/dev/null | awk '{print $NF}')" in
                    1) sb_state="enabled" ;;
                    0) sb_state="disabled" ;;
                esac
            fi
            echo "  Secure Boot state at enrollment: $sb_state"
            if [[ "$sb_state" == "disabled" ]]; then
                echo "  (PCR 7 will bind to the SB-disabled state; this protects only"
                echo "   against SSD-only theft, not against booting a foreign kernel"
                echo "   on this laptop.)"
            fi
            # Resolve the underlying LUKS partition from the open mapper.
            # `cryptsetup status` prints `device:  /dev/<part>` for the
            # backing block device. Whitespace varies between cryptsetup
            # builds, so use awk for robustness.
            local luks_dev
            luks_dev=$(cryptsetup status cryptroot 2>/dev/null \
                | awk '/^[[:space:]]*device:/ {print $2}')
            if [[ -z "$luks_dev" || ! -b "$luks_dev" ]]; then
                echo "warn: could not resolve cryptroot's backing device;" >&2
                echo "      skipping TPM2 enrollment. Run systemd-cryptenroll" >&2
                echo "      manually after first boot." >&2
            else
                echo
                echo ">> enrolling TPM2 keyslot on $luks_dev (PCR 7) …"
                if systemd-cryptenroll \
                    --tpm2-device=auto \
                    --tpm2-pcrs=7 \
                    --unlock-key-file="$EGGHEAD_LUKS_PASSWORD_FILE" \
                    "$luks_dev"; then
                    echo "  TPM2 keyslot enrolled; passphrase keyslot retained as fallback."
                else
                    echo "warn: systemd-cryptenroll failed (see output above);" >&2
                    echo "      install will continue using the passphrase keyslot only." >&2
                fi
            fi
        fi
    fi

    # 9. nixos-install. extra-experimental-features keeps things
    # working on a stock installer ISO without nix-command/flakes
    # enabled (see flake-modules/nix-settings.nix — that only lands
    # on the installed system). niri.cachix.org keeps niri's Rust
    # crates off crates.io (slow / rate-limited / fails on 4-core
    # T480 builds).
    # --no-root-passwd: the wizard always emits a
    # `users.users.root.initialHashedPassword` into the bridge (default
    # "recovery", overridable per-host, "" = no-login). nixos-install's
    # own end-of-run interactive root-password prompt would either ask
    # for something we've already declared declaratively, or block
    # forever on a non-interactive install. Skip it unconditionally.
    echo ">> running nixos-install …"
    nixos-install --root /mnt --flake "$flake_root#$HOSTNAME" \
        --no-root-passwd \
        --option extra-experimental-features "nix-command flakes" \
        --option extra-substituters "https://niri.cachix.org" \
        --option extra-trusted-public-keys \
            "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="

    # 10. Post-install: HM bootstrap + source clone + next-steps text.
    do_install_post
}


do_install_post() {
    # On success, drop the backup. We leave the working-tree change
    # in place — it represents the actual hardware UUIDs of this
    # machine and should be committed + pushed once the new system
    # boots and you can verify everything works.
    cleanup_hwcfg_artifacts

    # Backup secret material: populate /mnt/persist/etc/{restic,ssh-restic}/
    # with the per-host SSH key, the pinned TrueNAS known_hosts entry,
    # and the repo password (OLD on re-install, freshly-generated on
    # new install). Idempotent within an install (safe to re-invoke on
    # an aborted run if /mnt is still mounted). Skipped if backup
    # wasn't enabled in egghead.
    do_install_backup_material

    # Cross-host seeding: for each entry in EGGHEAD_SEED_USERS_FILE,
    # invoke backup-restore (via nixos-enter into /mnt so the wrapper's
    # closure is available) to pull /persist/home/<src-user> from the
    # source host's repo into /mnt/persist/home/<this-user>. NEVER
    # pulls /persist itself (system state is always host-specific:
    # machine-id, NetworkManager, ssh host keys).
    do_install_seed_users

    # Optional chained steps: seed ~/nixos for every HM-enabled user
    # and bootstrap each user's home-manager profile before reboot.
    # Both default ON; opt out via --no-clone-sources / --no-install-hm.
    # Failures are non-fatal: cloning is best-effort (depends on live-
    # USB network), HM bootstrap has its own retry on first boot via
    # the systemd units. We log + continue rather than aborting the
    # whole install if either step fails — the system is already
    # installed and bootable; these steps are smoothing the first-
    # boot UX, not gating it.
    if (( CLONE_SOURCES )); then
        echo
        echo "▶ chain step: clone ~/nixos for each HM user (--no-clone-sources to skip)"
        if ! do_clone_sources "$flake_root"; then
            echo
            echo ">> warning: clone step had failures; continuing." >&2
            echo "   You can re-run by mounting /mnt and re-invoking --install," >&2
            echo "   or by manually cloning from each user's home after first boot:" >&2
            echo "     git clone $SEED_REPO_URL ~/nixos" >&2
        fi
    else
        echo
        echo "▶ chain step: skipping ~/nixos clone (--no-clone-sources)"
    fi

    if (( INSTALL_HM_AUTO )); then
        echo
        echo "▶ chain step: bootstrap home-manager for each user (--no-install-hm to skip)"
        # Run in a subshell so any `exit N` inside do_install_hm
        # terminates only the subshell, not the install script.
        # do_install_hm currently uses `exit 3` and `exit 4` for its
        # own error paths; in chained mode we want those to be
        # warnings, not script-killing aborts.
        if ! ( do_install_hm ); then
            echo
            echo ">> warning: HM bootstrap had failures; continuing." >&2
            echo "   The systemd units will retry automatically on first boot." >&2
            echo "   Or re-run after reboot: sudo $0 --install-hm" >&2
        fi
    else
        echo
        echo "▶ chain step: skipping HM bootstrap (--no-install-hm)"
    fi

    # Build the next-steps text dynamically based on what was already
    # done in the chain. The original block always printed the manual
    # commands for steps that may now have run automatically.
    local hm_step_text clone_step_text
    if (( INSTALL_HM_AUTO )); then
        hm_step_text="\
  2. Home-manager profiles were bootstrapped above as part of this
     install. If any user's bootstrap failed (e.g. WiFi wasn't up
     yet on the live USB), the systemd units will retry on first
     boot. To re-trigger manually after reboot:
       sudo $0 --install-hm"
    else
        hm_step_text="\
  2. (Optional, but recommended) Bootstrap home-manager profiles
     before reboot. Runs each user's HM activation via nixos-enter
     into /mnt — saves a reboot's worth of \"did the units fire?\"
     uncertainty:

       sudo $0 --install-hm

     If skipped, the same units run on first boot via systemd
     (gated on network-online.target; they self-retry on the next
     boot if WiFi isn't up yet)."
    fi

    if (( CLONE_SOURCES )); then
        clone_step_text="\
       - ~/nixos was cloned during install for each HM user. The
         PRIMARY user's clone has the regenerated
         hardware-configuration.nix already in its working tree, so
         the first commit-and-push on the new host is just:
           cd ~/nixos
           git status                                  # review
           git diff                                    # review changes
           git add -A
           git commit -m \"<host>: real hardware config\"
           git push"
    else
        clone_step_text="\
       - The hwconfig (with the real-hardware kernel modules) is in
         the working tree of THIS checkout (auto-staged by --install).
         To land it upstream from this machine before unmount:
           git status                                  # review
           git diff --cached                           # review staged
           git commit -m \"<host>: real hardware config\"
           git push
         Or re-run with the default seeding to put a clone
         (with the changes pre-populated) in the primary user's
         home for them to push from after first boot."
    fi

    # Extract the root initialPassword from the bridge (if any). The
    # wizard emits `users.users.root.initialPassword = "...";` only
    # when EGGHEAD_ROOT_PASSWORD was set. Hand-rolled hosts may not
    # have one — in that case we tell the operator they have no
    # recovery path beyond the live USB.
    local bridge_file="$flake_root/flake-modules/hosts/$HOSTNAME.nix"
    local root_pw=""
    if [[ -f "$bridge_file" ]]; then
        root_pw=$(sed -nE '/root = \{/,/\};/{s/^[[:space:]]*initialPassword = "(.*)";.*$/\1/p;}' "$bridge_file" \
            | head -1)
    fi
    local recovery_text=""
    if [[ -n "$root_pw" ]]; then
        recovery_text="\
  1a. RECOVERY ACCESS (write this down before reboot):

       Root password: $root_pw
       SSH from LAN : ssh root@<host-ip>
                      Find <host-ip> in your router admin UI, or
                      run \`ip a\` on a TTY (Ctrl-Alt-F2 if X breaks).
       Console      : log in as root on any TTY.
       FIRST THING after reboot: \`passwd root\` to rotate this
       password. It is in plain text inside the host bridge file."
    else
        recovery_text="\
  1a. RECOVERY ACCESS: none configured in this host's bridge.
       If first boot breaks the display manager / HM, your only
       option is to re-boot the install USB and chroot into /mnt.
       Re-run egghead with a non-empty root password to fix this
       on the next host."
    fi

    # Build a backup material summary block. Operator needs to record
    # the freshly-generated repo password (one-time only — we shred
    # the tmpfs file at script exit) and paste the new host's SSH
    # pubkey into TrueNAS' authorized_keys before the first daily
    # backup timer fires.
    local backup_block=""
    if [[ -n "${EGGHEAD_BACKUP_TRUENAS_HOST:-}" ]]; then
        backup_block="
  1b. BACKUP MATERIAL (write down the password NOW if newly-generated):

       Target repo : sftp://${EGGHEAD_BACKUP_TRUENAS_USER}@${EGGHEAD_BACKUP_TRUENAS_HOST}:${EGGHEAD_BACKUP_REPO_BASE}/${HOSTNAME}
       Password    : ${BACKUP_PASSWORD_SOURCE:-already-on-disk}"
        if [[ -n "${BACKUP_PASSWORD_PLAINTEXT:-}" ]]; then
            backup_block+="
       PLAINTEXT   : ${BACKUP_PASSWORD_PLAINTEXT}
       (record this in your password manager — re-installs need it)"
        fi
        backup_block+="
       SSH pubkey  : ${BACKUP_SSH_PUBKEY:-(missing — generate manually after first boot)}
       → paste pubkey into TrueNAS user ${EGGHEAD_BACKUP_TRUENAS_USER}'s authorized_keys
         BEFORE the first daily backup timer fires (default 03:00 local)."
        if [[ "${BACKUP_KNOWN_HOSTS_OK:-1}" != "1" ]]; then
            backup_block+="
       WARNING: ssh-keyscan ${EGGHEAD_BACKUP_TRUENAS_HOST} failed during install.
                After first boot, populate /persist/etc/ssh-restic/restic_known_hosts:
                  sudo ssh-keyscan -t ed25519,rsa ${EGGHEAD_BACKUP_TRUENAS_HOST} \\
                    | sudo tee /persist/etc/ssh-restic/restic_known_hosts"
        fi
    fi

    cat <<EOF

>> nixos-install finished.

Next steps (in order):

  1. Set passwords for all interactive users (initialPassword in the
     host bridge is just "changeme" so login works exactly once):

       nixos-enter --root /mnt -c 'passwd p'
       nixos-enter --root /mnt -c 'passwd m'    # if applicable
       nixos-enter --root /mnt -c 'passwd s'    # if applicable

${recovery_text}
${backup_block}

${hm_step_text}

  3. Release /mnt and reboot:

       sudo $0 --unmount
       reboot

  4. After first boot:

${clone_step_text}
       - Hibernate-resume (any host with swap): the disko factory
         provisioned a swap partition at /dev/disk/by-partlabel/disk-
         main-swap and the disko module sets boot.resumeDevice to
         that path automatically. No first-boot kernelParam wart.

EOF
}

# ── --install chain step: clone ~/nixos for each HM-enabled user ──
# Discovers HM-enabled users by enumerating the
# home-manager-bootstrap-<user>.service unit files generated by
# flake-modules/home-manager-bootstrap.nix. For each user, runs
# `git clone $SEED_REPO_URL ~/nixos` inside /mnt as that user via
# nixos-enter + runuser.
#
# For the PRIMARY user (read from `users.primary` via nix eval) the
# function additionally `cp`s the regenerated hardware-configuration.
# nix and (if it differs from origin's HEAD) the host bridge file
# from the install-time `flake_root` working tree into the user's
# fresh clone, so the working tree of that clone shows the same
# pre-staged-but-uncommitted changes that the install-time checkout
# carries. That makes the first git push from the new host a single
# commit-and-push instead of "regenerate hwconfig again on the
# installed system, deal with branch state, then push".
#
# Network requirement: HTTPS clone goes out over whatever network
# the live USB has (NetworkManager / iwd up). If offline, this
# step's failures are non-fatal — caller (do_install_post) logs a
# warning and continues. Users can clone manually after first boot.
#
# Idempotent: if a user already has ~/nixos/.git, the clone step is
# skipped for them. The hwconfig copy step always overwrites the
# target file (which is harmless — it's a regenerated artifact, not
# user content).
do_clone_sources() {
    local flake_root="$1"
    local sysroot="/mnt"

    if ! mountpoint -q "$sysroot" || [[ ! -d "$sysroot/etc/systemd/system" ]]; then
        echo "error: $sysroot is not a mounted, installed NixOS system." >&2
        echo "       (do_clone_sources must run after nixos-install,"  >&2
        echo "        before --unmount.)"                              >&2
        return 1
    fi

    if ! command -v nixos-enter >/dev/null 2>&1; then
        echo "warning: nixos-enter not found; cannot run clone step." >&2
        return 1
    fi

    # Enumerate HM users from the bootstrap unit files. Same source
    # of truth as do_install_hm — anything that has a bootstrap
    # service has an HM config, and that's the set that gets a clone.
    shopt -s nullglob
    local units=( "$sysroot/etc/systemd/system"/home-manager-bootstrap-*.service )
    shopt -u nullglob

    if (( ${#units[@]} == 0 )); then
        echo "note: no home-manager-bootstrap-*.service units found." >&2
        echo "      Skipping clone step (no HM-enabled users to seed)." >&2
        return 0
    fi

    # Read the primary user from the installed system's NixOS config.
    # We read it from the running flake (same source as nixos-install
    # used) rather than peeking inside /mnt, because /mnt doesn't
    # have a usable nix eval surface from the live USB.
    local primary_user
    primary_user=$(nix "${NIX_EXTRA_OPTS[@]}" "${NIX_SUBSTITUTER_OPTS[@]}" eval --refresh --impure --raw \
        "$flake_root#nixosConfigurations.$HOSTNAME.config.users.primary" 2>/dev/null || true)
    if [[ -z "$primary_user" ]]; then
        echo "warning: could not read users.primary for $HOSTNAME; hwconfig pre-staging will be skipped." >&2
    else
        echo ">> primary user: $primary_user (will receive pre-staged hwconfig)"
    fi

    local u user any_failed=0
    for u in "${units[@]}"; do
        # Parse "User=…" from the unit. systemd allows multiple
        # User= lines but our generator emits exactly one. head -1
        # is safe.
        user=$(grep -E '^User=' "$u" | head -1 | cut -d= -f2- | tr -d '[:space:]')
        if [[ -z "$user" ]]; then
            echo "warning: could not parse User= from $(basename "$u"); skipping." >&2
            any_failed=1
            continue
        fi

        local home="/home/$user"
        if [[ ! -d "$sysroot$home" ]]; then
            echo "warning: $sysroot$home does not exist; skipping clone for $user." >&2
            any_failed=1
            continue
        fi

        echo ">> seeding ~/nixos for $user"

        # Idempotency: skip if the clone already exists. Don't try
        # to update it — that's the user's call, not ours.
        if [[ -d "$sysroot$home/nixos/.git" ]]; then
            echo "   ✓ $home/nixos already exists; skipping clone."
        else
            # Clone via nixos-enter so we use the installed system's
            # git binary and CA certs (the live USB might have a
            # different git version / cert store). runuser -u drops
            # to the target user so the clone is owned correctly.
            set +e
            nixos-enter --root "$sysroot" -- \
                runuser -u "$user" -- \
                git clone --quiet "$SEED_REPO_URL" "$home/nixos"
            local rc=$?
            set -e
            if (( rc != 0 )); then
                echo "   ✗ clone failed (exit $rc) — likely no network on the live USB." >&2
                any_failed=1
                continue
            fi
            echo "   ✓ cloned $SEED_REPO_URL → $home/nixos"
        fi

        # Pre-stage hwconfig for the primary user only.
        if [[ -n "$primary_user" && "$user" == "$primary_user" ]]; then
            local clone_root="$sysroot$home/nixos"
            local src_hwcfg="$flake_root/hosts/$HOSTNAME/hardware-configuration.nix"
            local dst_hwcfg="$clone_root/hosts/$HOSTNAME/hardware-configuration.nix"
            local src_bridge="$flake_root/flake-modules/hosts/$HOSTNAME.nix"
            local dst_bridge="$clone_root/flake-modules/hosts/$HOSTNAME.nix"

            if [[ -f "$src_hwcfg" ]]; then
                # Ensure target dir exists (origin/main may not have
                # the hosts/<NEW>/ dir yet for a brand-new host).
                nixos-enter --root "$sysroot" -- \
                    runuser -u "$user" -- \
                    mkdir -p "$home/nixos/hosts/$HOSTNAME"
                cp -f "$src_hwcfg" "$dst_hwcfg"
                # Restore ownership (cp from root preserves root:root).
                nixos-enter --root "$sysroot" -- \
                    chown "$user:users" "$home/nixos/hosts/$HOSTNAME/hardware-configuration.nix" \
                          "$home/nixos/hosts/$HOSTNAME"
                echo "   ✓ pre-staged $dst_hwcfg in $user's clone"
            else
                echo "   note: no $src_hwcfg in install-time checkout; nothing to pre-stage." >&2
            fi

            # Always cp the host bridge too — if the install-time
            # working tree has any unstaged edit, this picks it up.
            # If the file is unchanged from origin, the cp is a
            # no-op as far as `git diff` in the clone is concerned.
            # For brand-new hosts (e.g. egghead-created) the bridge
            # won't exist in origin/main yet, so dst_bridge may not
            # exist — copy unconditionally as long as src_bridge does.
            if [[ -f "$src_bridge" ]]; then
                nixos-enter --root "$sysroot" -- \
                    runuser -u "$user" -- \
                    mkdir -p "$home/nixos/flake-modules/hosts"
                cp -f "$src_bridge" "$dst_bridge"
                nixos-enter --root "$sysroot" -- \
                    chown "$user:users" "$home/nixos/flake-modules/hosts/$HOSTNAME.nix" \
                          "$home/nixos/flake-modules/hosts"
                echo "   ✓ refreshed $dst_bridge in $user's clone"
            fi
        fi
    done

    if (( any_failed )); then
        return 4
    fi
    return 0
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

# ── --install chain: backup material + cross-host seeding ────────
#
# Both helpers below are invoked unconditionally by do_install_post.
# They early-exit when the operator didn't enable backups in egghead
# (the relevant EGGHEAD_* env vars are unset). They run BEFORE
# do_install_hm so the seeded ~/<user>/persist is in place by the
# time the HM activation runs for each user — HM impermanence then
# bind-mounts the right state into place.

# Generates per-host SSH key + repo password and writes them under
# /mnt/persist/etc/{restic,ssh-restic}/ so the installed system can
# back up on first boot without a chicken-and-egg credential dance.
#
# On re-install (EGGHEAD_IS_REINSTALL=yes), the password file is the
# OLD repo password (operator pasted from password manager) so the
# new install continues writing to the existing repo. On first
# install, generates a fresh 32-byte base64 password and prints it
# in the post-install summary so the operator can record it.
do_install_backup_material() {
    if [[ -z "${EGGHEAD_BACKUP_TRUENAS_HOST:-}" ]]; then
        return 0
    fi

    if ! mountpoint -q /mnt; then
        echo
        echo ">> warning: /mnt is not mounted; skipping backup material install." >&2
        echo "   Re-run host-setup.sh --install or populate manually:" >&2
        echo "     /persist/etc/restic/host.pass" >&2
        echo "     /persist/etc/ssh-restic/restic_ed25519{,.pub}" >&2
        echo "     /persist/etc/ssh-restic/restic_known_hosts" >&2
        return 0
    fi

    echo
    echo "▶ chain step: populate /mnt/persist/etc/{restic,ssh-restic}/ for backups"

    install -d -m 0700 /mnt/persist/etc/restic
    install -d -m 0700 /mnt/persist/etc/ssh-restic

    # ── repo URL pinfile ────────────────────────────────────────────
    # Written so scripts/preimpermanence-restore.sh (and any future
    # ad-hoc restic invocation) can discover the canonical repo URL
    # from a freshly-installed system without parsing the nix-built
    # `backup-restore` wrapper. The declarative backup module
    # synthesizes the exact same URL from its options block.
    local repo_url="sftp:${EGGHEAD_BACKUP_TRUENAS_USER:-restic-backup}@${EGGHEAD_BACKUP_TRUENAS_HOST}:${EGGHEAD_BACKUP_REPO_BASE:-/mnt/zrust/backup/restic}/${HOSTNAME}"
    local repo_url_file="/mnt/persist/etc/restic/host.repo"
    install -m 0644 /dev/null "$repo_url_file"
    printf '%s\n' "$repo_url" > "$repo_url_file"
    echo "  wrote $repo_url_file ($repo_url)"

    # ── repo password ─────────────────────────────────────────────
    local pw_file="/mnt/persist/etc/restic/host.pass"
    local provided_pw=""
    if [[ -n "${EGGHEAD_BACKUP_REPO_PASSWORD_FILE:-}" ]] && \
       [[ -f "$EGGHEAD_BACKUP_REPO_PASSWORD_FILE" ]]; then
        provided_pw=$(< "$EGGHEAD_BACKUP_REPO_PASSWORD_FILE")
    fi

    if [[ "${EGGHEAD_IS_REINSTALL:-no}" == "yes" ]]; then
        if [[ -z "$provided_pw" ]]; then
            echo "  warning: re-install but no old repo password supplied; backup will FAIL until you set it manually." >&2
        else
            install -m 0400 /dev/null "$pw_file"
            printf '%s' "$provided_pw" > "$pw_file"
            BACKUP_PASSWORD_SOURCE="reused old password from egghead"
        fi
    else
        if [[ -n "$provided_pw" ]]; then
            # Operator-supplied first-install password (rare, but supported).
            install -m 0400 /dev/null "$pw_file"
            printf '%s' "$provided_pw" > "$pw_file"
            BACKUP_PASSWORD_SOURCE="provided by operator (kept)"
        else
            # Fresh password: 32 random bytes base64'd (~44 chars).
            install -m 0400 /dev/null "$pw_file"
            BACKUP_PASSWORD_PLAINTEXT=$(openssl rand -base64 32 2>/dev/null \
                || head -c 32 /dev/urandom | base64)
            printf '%s' "$BACKUP_PASSWORD_PLAINTEXT" > "$pw_file"
            BACKUP_PASSWORD_SOURCE="freshly generated (RECORD IT — printed in summary)"
        fi
    fi
    echo "  wrote $pw_file ($BACKUP_PASSWORD_SOURCE)"

    # ── SSH key ────────────────────────────────────────────────────
    local key="/mnt/persist/etc/ssh-restic/restic_ed25519"
    if [[ ! -f "$key" ]]; then
        ssh-keygen -t ed25519 -N "" -C "restic@${HOSTNAME}" -f "$key" >/dev/null
        chmod 0600 "$key"
        chmod 0644 "${key}.pub"
        echo "  wrote $key (ed25519, no passphrase)"
    else
        echo "  $key already exists; reusing"
    fi
    BACKUP_SSH_PUBKEY=$(< "${key}.pub")

    # ── known_hosts ───────────────────────────────────────────────
    # Pin the TrueNAS SSH host key now so the first restic run won't
    # prompt. If keyscan fails (no network on the live USB, NAS off,
    # etc.) we still proceed but the post-install summary tells the
    # operator they need to populate this file on first boot.
    local kh="/mnt/persist/etc/ssh-restic/restic_known_hosts"
    if [[ ! -s "$kh" ]]; then
        echo "  ssh-keyscan ${EGGHEAD_BACKUP_TRUENAS_HOST}..."
        if ssh-keyscan -T 5 -t ed25519,rsa "${EGGHEAD_BACKUP_TRUENAS_HOST}" \
            > "$kh" 2>/dev/null && [[ -s "$kh" ]]; then
            chmod 0644 "$kh"
            echo "  wrote $kh"
            BACKUP_KNOWN_HOSTS_OK=1
        else
            echo "  warning: ssh-keyscan ${EGGHEAD_BACKUP_TRUENAS_HOST} failed (network?); backups will fail until you populate $kh manually." >&2
            BACKUP_KNOWN_HOSTS_OK=0
            rm -f "$kh"
        fi
    else
        echo "  $kh already populated; reusing"
        BACKUP_KNOWN_HOSTS_OK=1
    fi
}

# Iterates EGGHEAD_SEED_USERS_FILE (a JSON array of
# {login, fromHost, fromUser, password}) and invokes
# `backup-restore --from-host <fh> --password-file <tmp> \
#                 --seed-from-user <fromUser> --seed-to-user <login>`
# inside the installed system via nixos-enter, with the restored
# tree landing at /mnt/persist/home/<login>. Skipped if no seed
# users were declared, or backups weren't enabled.
do_install_seed_users() {
    if [[ -z "${EGGHEAD_SEED_USERS_FILE:-}" ]] || \
       [[ ! -f "$EGGHEAD_SEED_USERS_FILE" ]]; then
        return 0
    fi
    if ! mountpoint -q /mnt; then
        echo
        echo ">> warning: /mnt not mounted; skipping cross-host seeding." >&2
        echo "   Re-run from a chroot or use sudo backup-restore after first boot." >&2
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo
        echo ">> warning: jq not on PATH; skipping cross-host seeding." >&2
        return 0
    fi

    local seed_count
    seed_count=$(jq 'length' < "$EGGHEAD_SEED_USERS_FILE")
    if (( seed_count == 0 )); then
        return 0
    fi

    echo
    echo "▶ chain step: cross-host seed $seed_count user(s) before reboot"

    local i login from_host from_user password
    for (( i = 0; i < seed_count; i++ )); do
        login=$(jq -r ".[$i].login"    < "$EGGHEAD_SEED_USERS_FILE")
        from_host=$(jq -r ".[$i].fromHost" < "$EGGHEAD_SEED_USERS_FILE")
        from_user=$(jq -r ".[$i].fromUser" < "$EGGHEAD_SEED_USERS_FILE")
        password=$(jq -r ".[$i].password"  < "$EGGHEAD_SEED_USERS_FILE")

        echo
        echo "  seeding ${login}'s persisted state  ←  ${from_user}@${from_host}"

        # Materialize the source-host password inside /mnt's runtime
        # tmpfs so the wrapper running under nixos-enter can read it.
        local src_pw_file="/mnt/run/seed-${login}.pass"
        install -d -m 0700 /mnt/run
        install -m 0600 /dev/null "$src_pw_file"
        printf '%s' "$password" > "$src_pw_file"

        # The user's home dir under /persist is populated by
        # impermanence on first boot. We restore directly under
        # /mnt/persist/home/<login>/, which is where impermanence
        # bind-mounts FROM on the live system.
        local uid gid
        uid=$(nixos-enter --root /mnt -c "id -u $login" 2>/dev/null || echo "")
        gid=$(nixos-enter --root /mnt -c "id -g $login" 2>/dev/null || echo "")
        if [[ -z "$uid" ]]; then
            echo "  warning: user $login does not yet exist inside /mnt; skipping seed for this user." >&2
            rm -f "$src_pw_file"
            continue
        fi
        install -d -m 0700 -o "$uid" -g "$gid" "/mnt/persist/home/${login}"

        # Run the restore inside the installed system (so the
        # `backup-restore` wrapper, restic, openssh, rsync are all on
        # PATH from the system closure rather than relying on the
        # live ISO). The wrapper's --seed-from-user/--seed-to-user
        # handles the source→dest user-rename case (e.g. seed
        # alice on new host from user p on pb-x1).
        set +e
        nixos-enter --root /mnt -c \
            "backup-restore --from-host '${from_host}' --password-file '/run/seed-${login}.pass' --seed-from-user '${from_user}' --seed-to-user '${login}' --target / >/dev/null"
        local rc=$?
        set -e
        # Shred the password file unconditionally.
        shred -u "$src_pw_file" 2>/dev/null || rm -f "$src_pw_file"
        if (( rc != 0 )); then
            echo "  warning: seed for $login failed (exit $rc); continuing with other users." >&2
        else
            echo "  ✓ seeded ${login}"
        fi
    done
}

# ── dispatch ──────────────────────────────────────────────────────
case "$MODE" in
    unmount)        do_unmount ;;
    install)        do_install ;;
    install-hm)     do_install_hm ;;
    audio-discover) do_audio_discover ;;
    hm-switch)      do_hm_switch ;;
esac
