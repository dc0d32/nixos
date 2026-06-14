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
# Pre-wipe: if the target disk has a previous install (LUKS, btrfs,
# or any other filesystem signatures), the kernel's block-layer cache
# can misidentify the freshly-mkfs'd partition during disko's
# subvolume-creation mount step. This script SSHes in first to run
# `wipefs -af` on the disko primary disk, clearing all signatures so
# the kernel starts clean. The disk path is derived from the flake
# config (disko.devices.disk.main.device).
#
# This script is intentionally minimal — `nixos-anywhere --help`
# documents every flag if you need to customize beyond the basics.
#
# Retire when: nixos-anywhere upstream gains a config-file-based
# convenience wrapper, or the flake outgrows the one-shot install
# pattern.
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <hostname> <target-ip> [extra nixos-anywhere args]" >&2
    echo >&2
    echo "Example: $0 pb-t480 192.168.1.42" >&2
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

# Derive the primary disk path from the flake config and wipe all
# filesystem/partition-table signatures. This prevents stale kernel
# block-layer state from causing disko's btrfs mount step to fail on
# repave (seen when overwriting a previous LUKS or btrfs install).
DISK=$(nix eval --raw "${FLAKE_ROOT}#nixosConfigurations.${HOSTNAME}.config.disko.devices.disk.main.device" 2>/dev/null || true)
if [[ -n "$DISK" ]]; then
    echo "==> pre-wipe: clearing signatures on ${DISK} at root@${TARGET}"
    ssh "root@${TARGET}" "wipefs -af '${DISK}'" || {
        echo "    (pre-wipe failed or skipped — continuing anyway)" >&2
    }
    echo
fi

echo "==> installing .#${HOSTNAME} onto root@${TARGET}"
echo "    flake root: ${FLAKE_ROOT}"
echo

exec nix run github:nix-community/nixos-anywhere -- \
    --flake "${FLAKE_ROOT}#${HOSTNAME}" \
    --target-host "root@${TARGET}" \
    "$@"
