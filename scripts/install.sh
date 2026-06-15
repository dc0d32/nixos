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
# --force-kexec: by default nixos-anywhere skips kexec when it
# detects the NixOS installer ISO (VARIANT_ID=installer in
# /etc/os-release). On a repave — re-running the installer over a
# previous install, especially one that used LUKS — the installer
# kernel may still hold cached partition/superblock state from the
# old layout. Symptom seen in the wild: after mkfs.btrfs succeeds
# and blkid agrees "TYPE=btrfs", disko's subvolume-creation mount
# step (which runs without -t, relying on autodetection) is dispatched
# to the *vfat* filesystem module and fails with
# "fsconfig() failed: vfat: Unknown parameter 'subvol'". Forcing
# kexec boots a fresh kernel with no cached state, so disko sees
# the disk cleanly. The cost (a couple of minutes for the kexec) is
# worth paying unconditionally — even on a first install, kexec'ing
# into nixos-anywhere's pinned image makes the install deterministic
# instead of depending on whatever installer ISO version the operator
# happens to have on the USB stick.
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

echo "==> installing .#${HOSTNAME} onto root@${TARGET}"
echo "    flake root: ${FLAKE_ROOT}"
echo

exec nix run github:nix-community/nixos-anywhere -- \
    --flake "${FLAKE_ROOT}#${HOSTNAME}" \
    --target-host "root@${TARGET}" \
    --force-kexec \
    "$@"
