#!/usr/bin/env bash
# seed-from-host — pull /persist/home/<login> from ANOTHER host's
# restic repo into this host's /persist/home/<login>. Use on a
# fresh install when you want to carry user state from another
# host (e.g. moving from pb-t480 to pb-x1).
#
# Requires init-backup.sh has already run on THIS host (we reuse
# its SSH key + known_hosts to talk to the NAS), and that the
# operator can paste the OTHER host's repo password.
#
# Seeding never touches /persist itself (system state — machine-id,
# NetworkManager, SSH host keys — is always host-specific).
#
# Retire when: backup module learns about cross-host seeding as a
# first-class flow (re-import from history if you want that).
set -euo pipefail

NAS_HOST="${NAS_HOST:-nas.lan}"
NAS_USER="${NAS_USER:-restic-backup}"
NAS_PORT="${NAS_PORT:-22}"
REPO_BASE="${REPO_BASE:-/mnt/zrust/backup/restic}"
SSH_DIR=/persist/etc/ssh-restic
KEY="$SSH_DIR/restic_ed25519"
KNOWN="$SSH_DIR/restic_known_hosts"

FROM_HOST=""
USER_NAME=""

usage() {
    cat <<EOF
Usage: sudo $0 --from <other-host> --user <login> [options]

Restores /persist/home/<login> from <other-host>'s restic repo into
this host's /persist/home/<login>.

Options:
  --from   HOST      source host (its restic repo is the data source)
  --user   LOGIN     user account whose home to pull
  --nas-host HOST    SFTP endpoint (default ${NAS_HOST})
  --nas-user USER    SFTP user (default ${NAS_USER})
  --nas-port PORT    SFTP port (default ${NAS_PORT})
  --repo-base PATH   parent of per-host repos (default ${REPO_BASE})
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)      FROM_HOST="$2"; shift 2;;
        --user)      USER_NAME="$2"; shift 2;;
        --nas-host)  NAS_HOST="$2"; shift 2;;
        --nas-user)  NAS_USER="$2"; shift 2;;
        --nas-port)  NAS_PORT="$2"; shift 2;;
        --repo-base) REPO_BASE="$2"; shift 2;;
        -h|--help)   usage; exit 0;;
        *) echo "unknown arg: $1" >&2; usage >&2; exit 2;;
    esac
done

if [[ -z "$FROM_HOST" || -z "$USER_NAME" ]]; then
    usage >&2
    exit 2
fi

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (writes under /persist/home)." >&2
    exit 1
fi

for f in "$KEY" "$KNOWN"; do
    if [[ ! -s "$f" ]]; then
        echo "error: $f missing. Run scripts/init-backup.sh first." >&2
        exit 1
    fi
done

if ! id "$USER_NAME" >/dev/null 2>&1; then
    echo "error: user '$USER_NAME' does not exist on this host." >&2
    exit 1
fi

echo "==> Paste the repo password for SOURCE host '${FROM_HOST}'."
read -r -s -p "    password: " src_pw
echo
if [[ -z "$src_pw" ]]; then
    echo "error: empty password." >&2
    exit 1
fi

PASS_TMP=$(mktemp)
trap 'rm -f "$PASS_TMP"' EXIT
chmod 0600 "$PASS_TMP"
printf '%s\n' "$src_pw" > "$PASS_TMP"
unset src_pw

export RESTIC_REPOSITORY="sftp://${NAS_USER}@${NAS_HOST}:${REPO_BASE}/${FROM_HOST}"
export RESTIC_PASSWORD_FILE="$PASS_TMP"
SSH_CMD="ssh -i ${KEY} -o UserKnownHostsFile=${KNOWN} -o StrictHostKeyChecking=yes -o BatchMode=yes -o Port=${NAS_PORT}"

echo "==> validating access to source repo"
if ! restic --option "sftp.command=${SSH_CMD} %h" snapshots --no-lock >/dev/null 2>&1; then
    echo "error: cannot open source repo at $RESTIC_REPOSITORY." >&2
    echo "       Either the password is wrong or your host's pubkey" >&2
    echo "       is not authorized on the NAS." >&2
    exit 1
fi

INCLUDE="/run/restic-snapshots/persist/home/${USER_NAME}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"; rm -f "$PASS_TMP"' EXIT

echo "==> restoring ${INCLUDE} from ${FROM_HOST}'s latest snapshot"
restic --option "sftp.command=${SSH_CMD} %h" restore latest \
    --include "$INCLUDE" --target "$STAGE"

SRC="$STAGE/run/restic-snapshots/persist/home/${USER_NAME}"
if [[ ! -d "$SRC" ]]; then
    echo "error: no data under $SRC after restore. Did ${FROM_HOST}" >&2
    echo "       have a user named '${USER_NAME}'?" >&2
    exit 1
fi

DST="/persist/home/${USER_NAME}"
install -d -m 0700 -o "$USER_NAME" -g "$(id -gn "$USER_NAME")" "$DST"

echo "==> rsyncing into ${DST}"
rsync -aHAX "${SRC}/" "${DST}/"
chown -R "${USER_NAME}:$(id -gn "$USER_NAME")" "$DST"

echo
echo "==> done. Reboot (or relogin as ${USER_NAME}) to pick up the"
echo "    restored state via impermanence bind mounts."
