#!/usr/bin/env bash
# install — wrapper around nixos-anywhere that installs <hostname>
# onto a target machine reachable at <target-ip> over SSH.
#
# Prereqs on the target:
#   - Booted into the NixOS installer ISO (or any kexec image that
#     gives nixos-anywhere an SSH foothold).
#   - Networking up.
#   - Root SSH (the installer ISO has it enabled by default; on
#     other images set a root password or paste your pubkey into
#     /root/.ssh/authorized_keys).
#
# Prereqs locally:
#   - This flake checked out and `cd`-ed into.
#   - nix with flakes + nix-command enabled.
#   - The host bridge flake-modules/hosts/<hostname>.nix exists.
#
# Pre-wipe (the surgical version): on a repave — re-running over a
# previous install — the installer kernel may still hold *cached*
# block-layer state (page cache for the device node, and the
# auto-detected filesystem type per partition) from the old layout.
# This state survives even after disko/mkfs.btrfs writes a fresh
# superblock, because nothing has told the kernel to drop the cache.
# Symptom: blkid reports TYPE=btrfs (userspace re-reads the disk),
# but `mount(2)` one line later dispatches to the *vfat* module and
# fails with "fsconfig() failed: vfat: Unknown parameter 'subvol'".
#
# Fix: SSH in before nixos-anywhere and run a full cleanup on the
# disko primary disk:
#   wipefs -af         clear on-disk FS / LUKS / partition-table sigs
#   sgdisk --zap-all   nuke GPT primary + backup headers
#   dd ... bs=1M       zero the first 16 MiB to obliterate LUKS hdrs
#                      and any stray superblocks in known-bad ranges
#   blockdev --flushbufs  *** drop the kernel's page cache for the
#                            device — this is what actually fixes
#                            the vfat-vs-btrfs mismatch ***
#   partprobe          force kernel to re-read the (now empty) GPT
#   udevadm settle     wait for /dev/disk/by-* symlinks to catch up
#
# We use --impure on the nix eval so it works on placeholder hosts
# (those gate `system.build.toplevel` on NIXOS_ALLOW_PLACEHOLDER=1
# — but the disk path itself doesn't depend on toplevel, the eval
# just needs to be allowed past the placeholder assertion). The
# eval is fatal if it fails: silently skipping the pre-wipe is what
# the previous attempt did, and that masked the bug.
#
# Placeholder hardware config: a brand-new host ships
# hosts/<name>/hardware-configuration.nix as the all-zeros placeholder,
# which carries a NIXOS_ALLOW_PLACEHOLDER assertion that aborts
# evaluation of system.build.toplevel. That creates a chicken-and-egg
# for a fresh install: you can't build the system until the hardware
# config is real, but you can't generate the real one until the machine
# is running. This script breaks the cycle by handing nixos-anywhere
# `--generate-hardware-config nixos-generate-config <path>` whenever the
# host's file is still the placeholder. nixos-anywhere then SSHes into
# the target after kexec, runs `nixos-generate-config --show-hardware-
# config --no-filesystems` (the --no-filesystems matters — disko owns
# fileSystems/swapDevices), writes the result over the placeholder, and
# only THEN builds toplevel — so the assertion never fires. The flag is
# omitted once the file is real, so re-paving an already-provisioned
# host respects its committed hardware-configuration.nix.
#
# This script is intentionally minimal beyond that — `nixos-anywhere
# --help` documents every flag if you need to customize further.
#
# Retire when: nixos-anywhere upstream gains a config-file-based
# convenience wrapper, or the flake outgrows the one-shot install
# pattern.
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <hostname> <target-ip> [extra nixos-anywhere args]" >&2
    echo >&2
    echo "Example: $0 pb-t480 192.0.2.42" >&2
    exit 2
fi

HOSTNAME="$1"
TARGET="$2"
shift 2

FLAKE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

if [[ ! -f "$FLAKE_ROOT/flake-modules/hosts/${HOSTNAME}.nix" ]]; then
    echo "error: flake-modules/hosts/${HOSTNAME}.nix not found." >&2
    echo "       Add the host bridge before running this." >&2
    exit 1
fi

echo "==> installing .#${HOSTNAME} onto root@${TARGET}"
echo "    flake root: ${FLAKE_ROOT}"
echo

echo "==> deriving primary disk path from disko config"
DISK=$(NIXOS_ALLOW_PLACEHOLDER=1 nix eval --raw --impure \
    "${FLAKE_ROOT}#nixosConfigurations.${HOSTNAME}.config.disko.devices.disk.main.device")
if [[ -z "$DISK" ]]; then
    echo "error: could not derive disko.devices.disk.main.device for ${HOSTNAME}" >&2
    exit 1
fi
echo "    disk: ${DISK}"
echo

echo "==> pre-wipe: clearing on-disk signatures + dropping kernel cache for ${DISK} on root@${TARGET}"
ssh "root@${TARGET}" "set -eux
    wipefs -af '${DISK}'
    sgdisk --zap-all '${DISK}' || true
    dd if=/dev/zero of='${DISK}' bs=1M count=16 conv=fsync status=none
    blockdev --flushbufs '${DISK}'
    partprobe '${DISK}' || true
    udevadm settle"
echo

# If the host's hardware-configuration.nix is still the placeholder,
# have nixos-anywhere regenerate it on the real hardware before the
# build (see the header note). Detected by the NIXOS_ALLOW_PLACEHOLDER
# assertion marker, which only the placeholder file carries.
HW_CONFIG="${FLAKE_ROOT}/hosts/${HOSTNAME}/hardware-configuration.nix"
NA_ARGS=()
PLACEHOLDER=0
if grep -q 'NIXOS_ALLOW_PLACEHOLDER' "$HW_CONFIG" 2>/dev/null; then
    PLACEHOLDER=1
    echo "==> ${HOSTNAME}: hardware-configuration.nix is still the placeholder"
    echo "    nixos-anywhere will regenerate it on the target"
    echo "    (nixos-generate-config --no-filesystems) before building."
    echo
    NA_ARGS+=(--generate-hardware-config nixos-generate-config "$HW_CONFIG")
fi

nix run github:nix-community/nixos-anywhere -- \
    --flake "${FLAKE_ROOT}#${HOSTNAME}" \
    --target-host "root@${TARGET}" \
    ${NA_ARGS+"${NA_ARGS[@]}"} \
    "$@"

# set -e guarantees we only reach here on a successful install.
if [[ ${PLACEHOLDER} == 1 ]]; then
    rel="${HW_CONFIG#"${FLAKE_ROOT}"/}"
    echo
    echo "==> ${rel} was regenerated from the real hardware and is now"
    echo "    dirty in your working tree. Review and commit it so the flake"
    echo "    builds without the placeholder next time:"
    echo "        git add ${rel}"
    echo "        git commit -m '${HOSTNAME}: real hardware-configuration.nix'"
fi
