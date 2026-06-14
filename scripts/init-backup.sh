#!/usr/bin/env bash
# init-backup — post-install bootstrap for flake-modules/backup.nix.
# Run ONCE on the host after first boot. Generates the per-host SSH
# key, pushes it to the NAS via ssh-copy-id (prompts NAS account
# password once), pins the NAS host key, writes the repo password
# into /persist, and either initializes a fresh restic repo or
# adopts an existing one for this hostname.
#
# Idempotent: re-running on an already-bootstrapped host detects
# the existing material and exits without re-doing anything
# destructive. To force regeneration, delete
# /persist/etc/ssh-restic and /persist/etc/restic and re-run.
#
# Reads the same options the backup module exposes by parsing flags
# (since the script runs from a checkout — not from the system
# closure — and shouldn't be coupled to a nix eval).
#
# Retire when: scripts/install.sh learns to run this automatically
# at the end of nixos-anywhere (would need a post-install hook).
set -euo pipefail

NAS_HOST="${NAS_HOST:-nas.lan}"
NAS_USER="${NAS_USER:-restic-backup}"
NAS_PORT="${NAS_PORT:-22}"
REPO_BASE="${REPO_BASE:-/mnt/zrust/backup/restic}"

usage() {
    cat <<EOF
Usage: sudo $0 [--nas-host HOST] [--nas-user USER] [--nas-port PORT]
                [--repo-base PATH]

Bootstrap restic backup on this host. Run after first boot of an
install that imports flake.modules.nixos.backup.

Defaults:
  --nas-host  ${NAS_HOST}
  --nas-user  ${NAS_USER}
  --nas-port  ${NAS_PORT}
  --repo-base ${REPO_BASE}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nas-host)  NAS_HOST="$2"; shift 2;;
        --nas-user)  NAS_USER="$2"; shift 2;;
        --nas-port)  NAS_PORT="$2"; shift 2;;
        --repo-base) REPO_BASE="$2"; shift 2;;
        -h|--help)   usage; exit 0;;
        *) echo "unknown arg: $1" >&2; usage >&2; exit 2;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (writes under /persist)." >&2
    exit 1
fi

if ! command -v restic >/dev/null 2>&1; then
    echo "error: restic not in PATH. This host should import" >&2
    echo "       flake.modules.nixos.backup (which installs restic)." >&2
    exit 1
fi

HOSTNAME="$(hostname)"
SSH_DIR=/persist/etc/ssh-restic
RESTIC_DIR=/persist/etc/restic
KEY="$SSH_DIR/restic_ed25519"
KNOWN="$SSH_DIR/restic_known_hosts"
PASS="$RESTIC_DIR/host.pass"

install -d -m 0700 -o root -g root "$SSH_DIR" "$RESTIC_DIR"

# 1. Repo password.
if [[ -s "$PASS" ]]; then
    echo "==> repo password already at $PASS — keeping."
else
    echo "==> Paste the restic repo password for ${HOSTNAME}."
    echo "    (For a reinstall: paste the SAME password the previous"
    echo "    install used. For a fresh host: any strong password)"
    read -r -s -p "    password: " repo_pw
    echo
    if [[ -z "$repo_pw" ]]; then
        echo "error: empty password." >&2
        exit 1
    fi
    install -m 0600 -o root -g root /dev/null "$PASS"
    printf '%s\n' "$repo_pw" > "$PASS"
    unset repo_pw
fi

# 2. SSH key.
if [[ -s "$KEY" && -s "${KEY}.pub" ]]; then
    echo "==> SSH key already at $KEY — keeping."
else
    echo "==> generating ed25519 SSH key at $KEY"
    ssh-keygen -t ed25519 -N "" -C "restic@${HOSTNAME}" -f "$KEY"
    chmod 0600 "$KEY"
    chmod 0644 "${KEY}.pub"
fi

# 3. Pin NAS host key.
if [[ -s "$KNOWN" ]] && grep -q "${NAS_HOST}" "$KNOWN"; then
    echo "==> NAS host key already pinned at $KNOWN — keeping."
else
    echo "==> pinning ${NAS_HOST}:${NAS_PORT} host key into $KNOWN"
    ssh-keyscan -p "$NAS_PORT" -t ed25519,rsa "$NAS_HOST" > "$KNOWN"
    chmod 0644 "$KNOWN"
    echo "    NAS host key fingerprint(s):"
    ssh-keygen -lf "$KNOWN" | sed 's/^/      /'
    echo "    (verify out-of-band — once is enough)"
fi

# 4. Push pubkey to NAS via ssh-copy-id. Tolerates re-runs (it
# detects key already present and skips). Prompts NAS password.
echo "==> installing pubkey into ${NAS_USER}@${NAS_HOST}:.ssh/authorized_keys"
echo "    (will prompt for the NAS account password)"
ssh-copy-id \
    -s \
    -i "${KEY}.pub" \
    -o "Port=${NAS_PORT}" \
    -o "UserKnownHostsFile=${KNOWN}" \
    -o "StrictHostKeyChecking=yes" \
    "${NAS_USER}@${NAS_HOST}" || {
    echo "warning: ssh-copy-id failed. Continuing — maybe the key was" >&2
    echo "         already installed; we'll know in step 5." >&2
}

# 5. Verify key auth.
echo "==> verifying key auth"
if ! sftp \
        -i "$KEY" \
        -o "Port=${NAS_PORT}" \
        -o "UserKnownHostsFile=${KNOWN}" \
        -o "StrictHostKeyChecking=yes" \
        -o "BatchMode=yes" \
        -b /dev/null \
        "${NAS_USER}@${NAS_HOST}" >/dev/null 2>&1; then
    echo "error: key auth still failing after ssh-copy-id." >&2
    echo "       Check the NAS sshd Match block and that" >&2
    echo "       ${NAS_HOST}:${REPO_BASE}/.ssh/authorized_keys" >&2
    echo "       has this host's pubkey:" >&2
    cat "${KEY}.pub" | sed 's/^/         /' >&2
    exit 1
fi
echo "    OK"

# 6. Init (or adopt) the repo.
export RESTIC_REPOSITORY="sftp://${NAS_USER}@${NAS_HOST}:${REPO_BASE}/${HOSTNAME}"
export RESTIC_PASSWORD_FILE="$PASS"
SSH_CMD="ssh -i ${KEY} -o UserKnownHostsFile=${KNOWN} -o StrictHostKeyChecking=yes -o BatchMode=yes -o Port=${NAS_PORT}"

echo "==> checking restic repo at $RESTIC_REPOSITORY"
if restic --option "sftp.command=${SSH_CMD} %h" snapshots --no-lock >/dev/null 2>&1; then
    echo "    existing repo found — adopting (no init needed)."
else
    echo "    no repo yet — initializing."
    restic --option "sftp.command=${SSH_CMD} %h" init
fi

echo
echo "==> done. Daily timer 'restic-backups-host.timer' will fire next."
echo "    To run a backup right now:  sudo systemctl start restic-backups-host.service"
echo "    To list snapshots:           sudo backup-snapshots"
echo "    To restore everything:       sudo backup-restore"
