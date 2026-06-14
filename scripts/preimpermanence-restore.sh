#!/usr/bin/env bash
# preimpermanence-restore.sh — restore a preimpermanence-tagged
# snapshot into /persist on a freshly-egghead'd host, BEFORE the
# user's first login.
#
# Why this exists:
#   After egghead nukes a host and re-installs it with impermanence +
#   backup, /persist is empty. The user's Bitwarden vault, Chrome
#   profile, FreeCAD configs, WiFi keys, etc. all live in restic
#   snapshots tagged `preimpermanence` (captured by
#   preimpermanence-backup.sh before the wipe). This script pulls
#   the latest such snapshot into /persist, preserving original
#   paths so the impermanence module's bind-mounts find every file
#   where it expects on next boot.
#
# What this does:
#   1. Reads repo URL + password + SSH key from /persist/etc/restic
#      and /persist/etc/ssh-restic (already populated by the
#      IS_REINSTALL=yes egghead flow). Operator can override any of
#      these via flags or env.
#   2. `restic snapshots --tag preimpermanence --host <host>` to
#      pick the snapshot — operator passes --snapshot-id to override
#      "latest".
#   3. `restic restore <snap> --target /persist <include args>` —
#      restores under /persist so that e.g. the snapshot's
#      /home/p/.config/Bitwarden lands at
#      /persist/home/p/.config/Bitwarden, exactly where
#      impermanence's users.p.directories bind-mount expects.
#   4. Optional: chown -R <login>:<group> /persist/home/<login> so
#      uid changes between old and new install don't lock the user
#      out of their own files.
#
# What this deliberately doesn't do:
#   * Reboot. Operator does that after verifying.
#   * Restore /persist/etc/machine-id or /persist/etc/ssh/ssh_host_*
#     unless --include-host-identity. Re-installs typically WANT
#     fresh host identity; pasting the old machine-id breaks
#     systemd-journal and can collide with external systems
#     (Tailscale, monitoring) that key off it.
#
# Retire when:
#   * All hosts have been migrated to impermanence + the declarative
#     backup module, AND the operator has done a real
#     `backup-restore` from a `auto`-tagged snapshot at least once
#     to validate the restore path. The preimpermanence snapshots
#     can then be `restic forget --tag preimpermanence --prune`'d.

set -euo pipefail

# -- defaults / args ---------------------------------------------------

TARGET="/persist"
SNAPSHOT="latest"
HOSTNAME_OVERRIDE=""
REPO_URL=""
REPO_PASS_FILE=""
SSH_KEY=""
KNOWN_HOSTS=""
INCLUDE_HOST_IDENTITY=0
INCLUDES=()
EXCLUDES=()
CHOWN_USERS=1
DRY_RUN=0

usage() {
    cat >&2 <<'EOF'
preimpermanence-restore.sh — restore preimpermanence snapshot into /persist

Usage: sudo preimpermanence-restore.sh [options]

Options:
  --target PATH            Restore root (default: /persist).
  --snapshot ID            Snapshot ID or "latest" (default: latest).
  --hostname NAME          Snapshot host filter (default: current hostname).
                           Use this to seed from another host's backup.
  --repo URL               Override repo URL. Default: read from
                           /persist/etc/restic/host.repo if present, else
                           construct from the backup module's evaluated
                           settings via `nix eval`.
  --password-file PATH     Override repo password file. Default:
                           /persist/etc/restic/host.pass.
  --ssh-key PATH           Override SSH identity. Default:
                           /persist/etc/ssh-restic/restic_ed25519.
  --known-hosts PATH       Override known_hosts. Default:
                           /persist/etc/ssh-restic/restic_known_hosts.
  --include PATTERN        Restore only matching paths (restic --include).
                           Repeatable. Default: restore everything in the
                           snapshot.
  --exclude PATTERN        Skip matching paths (restic --exclude).
                           Repeatable.
  --include-host-identity  Also restore /etc/machine-id and /etc/ssh/ssh_host_*
                           into /persist/etc/. DEFAULT: NO (the new install
                           usually wants fresh host identity).
  --no-chown               Skip the chown pass on /persist/home/<login>.
  --dry-run                Print everything but don't actually restore.
  -h, --help               This help.

Examples:
  # Standard restore of current host's latest preimpermanence snapshot
  sudo preimpermanence-restore.sh

  # Cross-host seeding: pull pb-x1's last snapshot into pb-t480's /persist
  sudo preimpermanence-restore.sh --hostname pb-x1 \
       --repo sftp:restic-backup@nas.lan:/mnt/zrust/backup/restic/pb-x1 \
       --password-file /root/pb-x1-repo.pass

  # Only restore the user home, skip system bits
  sudo preimpermanence-restore.sh --include /home
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --hostname) HOSTNAME_OVERRIDE="$2"; shift 2 ;;
    --repo) REPO_URL="$2"; shift 2 ;;
    --password-file) REPO_PASS_FILE="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --known-hosts) KNOWN_HOSTS="$2"; shift 2 ;;
    --include) INCLUDES+=("$2"); shift 2 ;;
    --exclude) EXCLUDES+=("$2"); shift 2 ;;
    --include-host-identity) INCLUDE_HOST_IDENTITY=1; shift ;;
    --no-chown) CHOWN_USERS=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root." >&2
    exit 1
fi

if [[ ! -d "$TARGET" ]]; then
    echo "error: $TARGET does not exist. Is impermanence + the persist subvol set up?" >&2
    exit 1
fi

# -- discover creds from /persist if not overridden --------------------

: "${REPO_PASS_FILE:=/persist/etc/restic/host.pass}"
: "${SSH_KEY:=/persist/etc/ssh-restic/restic_ed25519}"
: "${KNOWN_HOSTS:=/persist/etc/ssh-restic/restic_known_hosts}"

for f in "$REPO_PASS_FILE" "$SSH_KEY" "$KNOWN_HOSTS"; do
    if [[ ! -f "$f" ]]; then
        echo "error: required file missing: $f" >&2
        echo "  did egghead IS_REINSTALL=yes complete? Or override with --password-file/--ssh-key/--known-hosts." >&2
        exit 1
    fi
done

if [[ -z "$REPO_URL" ]]; then
    if [[ -s /persist/etc/restic/host.repo ]]; then
        REPO_URL=$(tr -d '[:space:]' </persist/etc/restic/host.repo)
    fi
fi

if [[ -z "$REPO_URL" ]]; then
    # Try to construct from the running backup module config. The
    # `backup-restore` wrapper has the URL embedded; we can parse it
    # out of its source rather than `nix eval` (which would need
    # network + flake access on the freshly-installed box).
    if command -v backup-restore >/dev/null 2>&1; then
        REPO_URL=$(grep -oE 'sftp:[^"]+' "$(command -v backup-restore)" | head -1 || true)
    fi
fi

if [[ -z "$REPO_URL" ]]; then
    echo "error: could not determine repo URL. Pass --repo explicitly." >&2
    exit 1
fi

HOSTNAME_USED="${HOSTNAME_OVERRIDE:-$(hostname)}"

echo "==> repo:     $REPO_URL"
echo "==> snapshot: $SNAPSHOT (host filter: $HOSTNAME_USED)"
echo "==> target:   $TARGET"

# -- restic env --------------------------------------------------------

# Pull SSH port from the same source as the backup module if available.
NAS_PORT="${NAS_PORT:-22}"

export RESTIC_REPOSITORY="$REPO_URL"
export RESTIC_PASSWORD_FILE="$REPO_PASS_FILE"
# Extract user@host from the repo URL for the ssh invocation.
sftp_endpoint=$(echo "$REPO_URL" | sed -E 's,^sftp:([^:]+):.*,\1,')
export RESTIC_SFTP_COMMAND="ssh -i $SSH_KEY -o UserKnownHostsFile=$KNOWN_HOSTS -o StrictHostKeyChecking=yes -o BatchMode=yes -p $NAS_PORT $sftp_endpoint -s sftp"

# -- pick snapshot -----------------------------------------------------

if [[ "$SNAPSHOT" == "latest" ]]; then
    echo "==> resolving latest preimpermanence snapshot for host=$HOSTNAME_USED"
    snaps_json=$(restic snapshots --tag preimpermanence --host "$HOSTNAME_USED" --json 2>/dev/null || true)
    if command -v jq >/dev/null 2>&1; then
        SNAPSHOT_RESOLVED=$(printf '%s' "$snaps_json" | jq -r '.[-1].short_id // empty')
    else
        SNAPSHOT_RESOLVED=$(printf '%s' "$snaps_json" | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s[-1]["short_id"] if s else "")')
    fi
    if [[ -z "${SNAPSHOT_RESOLVED:-}" || "$SNAPSHOT_RESOLVED" == "null" ]]; then
        echo "error: no preimpermanence-tagged snapshots found for host=$HOSTNAME_USED in $REPO_URL." >&2
        echo "       available snapshots:" >&2
        restic snapshots >&2 || true
        exit 1
    fi
    SNAPSHOT="$SNAPSHOT_RESOLVED"
    echo "    resolved to $SNAPSHOT"
fi

# -- assemble include/exclude args ------------------------------------

declare -a restore_args=(restore "$SNAPSHOT" --target "$TARGET")

if [[ ${#INCLUDES[@]} -gt 0 ]]; then
    for inc in "${INCLUDES[@]}"; do
        restore_args+=(--include "$inc")
    done
fi

if [[ $INCLUDE_HOST_IDENTITY -eq 0 ]]; then
    EXCLUDES+=(/etc/machine-id /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub)
fi

for ex in "${EXCLUDES[@]}"; do
    restore_args+=(--exclude "$ex")
done

# -- restore -----------------------------------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
    echo "    [dry-run] would run: restic ${restore_args[*]}"
else
    echo "==> restic ${restore_args[*]}"
    restic "${restore_args[@]}"
fi

# -- chown user homes --------------------------------------------------

if [[ $CHOWN_USERS -eq 1 && $DRY_RUN -eq 0 && -d "$TARGET/home" ]]; then
    echo "==> chown'ing $TARGET/home/<login> to match current passwd entries"
    for d in "$TARGET"/home/*/; do
        login=$(basename "$d")
        if id -u "$login" >/dev/null 2>&1; then
            uid=$(id -u "$login")
            gid=$(id -g "$login")
            echo "    $d -> $login ($uid:$gid)"
            chown -R "$uid:$gid" "$d"
        else
            echo "    skipping $d — no user '$login' on this system (pass --no-chown to keep numeric uids as-is)" >&2
        fi
    done
fi

cat <<EOF

==============================================================
   PRE-IMPERMANENCE RESTORE COMPLETE
==============================================================
Snapshot:  $SNAPSHOT
Target:    $TARGET

Next steps:
  1. sudo reboot
  2. Log in. Impermanence will bind-mount the restored /persist
     contents into the ephemeral root, so /home/<you>/.config/...,
     /etc/NetworkManager/system-connections, /var/lib/bluetooth
     etc. should all show up populated.
  3. If anything's missing, mount the persist subvol or inspect
     /persist directly to confirm files landed where expected.
EOF
