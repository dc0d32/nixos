#!/usr/bin/env bash
# preimpermanence-backup.sh — one-shot live-host backup BEFORE the
# host is nuked and re-egghead'd onto impermanence + the declarative
# backup module.
#
# Why this exists:
#   The declarative `flake.modules.nixos.backup` module assumes
#   /persist exists (impermanence). On hosts that haven't migrated
#   yet, /persist isn't there and the snapshot wrapper has nothing
#   to point at. This script bridges that gap: it captures the LIVE
#   filesystem state at exactly the paths impermanence will later
#   bind-mount, so that on the fresh host a `restic restore --target
#   /persist` lands every file where the new impermanence module
#   expects it (`/persist/etc/NetworkManager/system-connections`,
#   `/persist/home/<user>/...`, `/persist/var/lib/bluetooth`, ...).
#
#   Same per-host restic repo as the eventual declarative backup
#   module (same hostname-scoped path on the NAS, same password,
#   same SSH key). The only difference is the snapshot tag —
#   `preimpermanence` here, `auto` from the timer afterwards. When
#   the host is egghead'd with IS_REINSTALL=yes the operator pastes
#   the same password back in and the new install inherits all
#   snapshot history.
#
# What this does:
#   1. Generates a per-host ed25519 SSH key under
#      ${STATE_DIR}/id_ed25519 if missing.
#   2. ssh-keyscans the NAS into ${STATE_DIR}/known_hosts (pin) if
#      missing.
#   3. ssh-copy-ids the pubkey to ${NAS_USER}@${NAS_HOST} (prompts
#      for the NAS password interactively — that's the one and only
#      password prompt). Skipped if key auth already works.
#   4. Generates a per-host repo password at ${STATE_DIR}/repo.pass
#      if missing.
#   5. `restic init` if the repo doesn't exist yet.
#   6. `restic backup --tag preimpermanence --tag
#      preimpermanence-<date>` of:
#        * /home/<each-normal-user>            (whole tree, with junk excludes)
#        * /root
#        * /etc/NetworkManager/system-connections
#        * /etc/machine-id
#        * /etc/ssh/ssh_host_{ed25519,rsa}_key{,.pub}
#        * /var/lib/{bluetooth,fprint,iwd,upower,colord,
#                   power-profiles-daemon,tpm2-tss,systemd,nixos}
#        * /var/log
#        * /var/db/sudo/lectured
#      Exact set mirrors the defaults in
#      flake-modules/impermanence.nix:295-351.
#   7. Prints a BIG banner at the end with the repo URL, password,
#      SSH private key path, and NAS pubkey. Operator MUST stash
#      these in their password manager before nuking the host — they
#      are the only thing that can decrypt the snapshots later.
#
# What this deliberately doesn't do:
#   * Touch /persist on the source host (it almost certainly doesn't
#     exist yet, and the impermanence migration creates it).
#   * Wipe or modify anything — purely read + restic upload.
#   * Schedule itself (no systemd timer). The declarative backup
#     module owns scheduling once impermanence lands.
#
# Retire when:
#   * Every host in the flake has gone through impermanence + the
#     declarative backup module. At that point preimpermanence
#     snapshots are stale history that restic can `forget --tag
#     preimpermanence` once the operator is confident the migration
#     is permanent.

set -euo pipefail

# -- defaults / args ----------------------------------------------------

NAS_HOST="${NAS_HOST:-nas.lan}"
NAS_USER="${NAS_USER:-restic-backup}"
NAS_PORT="${NAS_PORT:-22}"
REPO_BASE="${REPO_BASE:-/mnt/zrust/backup/restic}"
STATE_DIR="${STATE_DIR:-/var/lib/preimpermanence-backup}"
EXTRA_PATHS=()
EXTRA_EXCLUDES=()
DRY_RUN=0
SKIP_PUBKEY_INSTALL=0
HOSTNAME_OVERRIDE=""

usage() {
    cat >&2 <<'EOF'
preimpermanence-backup.sh — one-shot live-host backup before impermanence rollout

Usage: sudo preimpermanence-backup.sh [options]

Options:
  --nas-host HOST          TrueNAS hostname (default: nas.lan, or $NAS_HOST)
  --nas-user USER          SFTP user on NAS (default: restic-backup, or $NAS_USER)
  --nas-port N             SSH port (default: 22, or $NAS_PORT)
  --repo-base PATH         NAS-side dataset root (default: /mnt/zrust/backup/restic,
                           or $REPO_BASE). Repo lands at <repo-base>/<hostname>.
  --state-dir PATH         Where to keep generated secrets across runs
                           (default: /var/lib/preimpermanence-backup,
                           or $STATE_DIR). Survives reruns but NOT the
                           host wipe — stash secrets off-host!
  --hostname NAME          Override hostname used for the repo path
                           (default: `hostname`).
  --extra-path PATH        Add an additional path to back up. Repeatable.
  --exclude PATTERN        Add an exclude pattern (restic syntax). Repeatable.
  --skip-pubkey-install    Skip ssh-copy-id; assume key auth already works.
  --dry-run                Print everything but don't actually init/backup.
  -h, --help               This help.

Environment:
  NAS_HOST, NAS_USER, NAS_PORT, REPO_BASE, STATE_DIR — same as flags.

Prereqs: restic, ssh, ssh-keygen, ssh-keyscan, ssh-copy-id (only if
the pubkey hasn't been installed on the NAS yet).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --nas-host) NAS_HOST="$2"; shift 2 ;;
    --nas-user) NAS_USER="$2"; shift 2 ;;
    --nas-port) NAS_PORT="$2"; shift 2 ;;
    --repo-base) REPO_BASE="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --hostname) HOSTNAME_OVERRIDE="$2"; shift 2 ;;
    --extra-path) EXTRA_PATHS+=("$2"); shift 2 ;;
    --exclude) EXTRA_EXCLUDES+=("$2"); shift 2 ;;
    --skip-pubkey-install) SKIP_PUBKEY_INSTALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

# -- root check ---------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (needs to read /etc/ssh/ssh_host_* and per-user files)." >&2
    exit 1
fi

# -- tools --------------------------------------------------------------

missing=()
for tool in restic ssh ssh-keygen ssh-keyscan; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+=("$tool")
    fi
done
if [[ $SKIP_PUBKEY_INSTALL -eq 0 ]] && ! command -v ssh-copy-id >/dev/null 2>&1; then
    missing+=("ssh-copy-id")
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: missing required tools: ${missing[*]}" >&2
    echo "  on NixOS: nix-shell -p restic openssh" >&2
    exit 1
fi

# -- state --------------------------------------------------------------

HOSTNAME_USED="${HOSTNAME_OVERRIDE:-$(hostname)}"
if [[ -z "$HOSTNAME_USED" ]]; then
    echo "error: hostname is empty; pass --hostname explicitly." >&2
    exit 1
fi

install -d -m 0700 "$STATE_DIR"

SSH_KEY="$STATE_DIR/id_ed25519"
SSH_PUB="$STATE_DIR/id_ed25519.pub"
KNOWN_HOSTS="$STATE_DIR/known_hosts"
REPO_PASS_FILE="$STATE_DIR/repo.pass"

if [[ ! -f "$SSH_KEY" ]]; then
    echo "==> generating ed25519 ssh key at $SSH_KEY"
    ssh-keygen -t ed25519 -N "" -C "preimpermanence-backup@${HOSTNAME_USED}" -f "$SSH_KEY"
    chmod 0600 "$SSH_KEY"
    chmod 0644 "$SSH_PUB"
fi

if [[ ! -s "$KNOWN_HOSTS" ]]; then
    echo "==> pinning NAS host key into $KNOWN_HOSTS (ssh-keyscan $NAS_HOST:$NAS_PORT)"
    ssh-keyscan -p "$NAS_PORT" -t ed25519,rsa "$NAS_HOST" >"$KNOWN_HOSTS"
    if [[ ! -s "$KNOWN_HOSTS" ]]; then
        echo "error: ssh-keyscan returned empty result. Is $NAS_HOST:$NAS_PORT reachable?" >&2
        exit 1
    fi
    chmod 0644 "$KNOWN_HOSTS"
fi

if [[ ! -f "$REPO_PASS_FILE" ]]; then
    echo "==> generating fresh restic repo password at $REPO_PASS_FILE"
    install -m 0600 /dev/null "$REPO_PASS_FILE"
    ssh-keygen -t ed25519 -N "" -C tmp -f /tmp/.tmp-pwgen-$$ >/dev/null
    # 256 bits of entropy, base64'd. Avoid `openssl` to keep
    # dependencies minimal.
    head -c 32 /dev/urandom | base64 | tr -d '\n=' >"$REPO_PASS_FILE"
    echo >>"$REPO_PASS_FILE"
    rm -f /tmp/.tmp-pwgen-$$ /tmp/.tmp-pwgen-$$.pub
    chmod 0600 "$REPO_PASS_FILE"
fi

# -- pubkey install on NAS ---------------------------------------------

SSH_OPTS=(-i "$SSH_KEY" -o "UserKnownHostsFile=$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -o "Port=$NAS_PORT")

# ssh-copy-id since OpenSSH 9.4 rejects multiple -i (the pubkey to
# install is its own -i; passing the identity again via $SSH_OPTS
# trips "ERROR: -i option must not be specified more than once").
# Build a stripped variant of SSH_OPTS without the -i arg.
SCID_OPTS=(-o "UserKnownHostsFile=$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -o "Port=$NAS_PORT")

# The NAS Match block pins restic-backup to `ForceCommand
# internal-sftp`, so `ssh ... true` always exits non-zero ("This
# service allows sftp connections only.") regardless of whether key
# auth worked. Probe with sftp instead — exit 0 only if both auth +
# subsystem succeed.
probe_key_auth() {
    sftp -b /dev/null -o BatchMode=yes -o ConnectTimeout=10 \
        "${SSH_OPTS[@]}" "${NAS_USER}@${NAS_HOST}" >/dev/null 2>&1
}

if [[ $SKIP_PUBKEY_INSTALL -eq 0 ]]; then
    # ssh-copy-id needs $HOME/.ssh to exist on the LOCAL side (uses
    # it for a temp file). Under sudo, $HOME=/root and on this fresh
    # box /root/.ssh may not exist yet.
    install -d -m 0700 "${HOME:-/root}/.ssh"

    echo "==> testing key auth to ${NAS_USER}@${NAS_HOST}:${NAS_PORT}"
    if probe_key_auth; then
        echo "    key auth already works; skipping ssh-copy-id."
    else
        # -s makes ssh-copy-id append via the SFTP channel, which is
        # the only thing our ForceCommand-restricted account allows.
        echo "==> ssh-copy-id -s ${NAS_USER}@${NAS_HOST} (you will be prompted for the NAS password)"
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "    [dry-run] would run: ssh-copy-id -s -i $SSH_PUB ${SCID_OPTS[*]} ${NAS_USER}@${NAS_HOST}"
        else
            ssh-copy-id -s -i "$SSH_PUB" "${SCID_OPTS[@]}" "${NAS_USER}@${NAS_HOST}"
            if ! probe_key_auth; then
                echo "error: key auth still failing after ssh-copy-id. Check NAS sshd config (Match block, AuthorizedKeysFile)." >&2
                exit 1
            fi
            echo "    key auth confirmed."
        fi
    fi
fi

# -- restic env ---------------------------------------------------------

REPO_URL="sftp:${NAS_USER}@${NAS_HOST}:${REPO_BASE}/${HOSTNAME_USED}"

# restic's sftp backend shells out to plain `sftp` (which itself
# shells out to `ssh`). There IS no RESTIC_SFTP_COMMAND env var —
# the only way to customise the ssh invocation is the per-call
# `-o sftp.command=…` flag, OR via SSH's standard config files.
# Easiest: merge our pinned host keys + identity into root's default
# ~/.ssh/{known_hosts,config} so the default sftp invocation just
# works. Idempotent — `sort -u` dedupes.
SSH_HOME="${HOME:-/root}/.ssh"
install -d -m 0700 "$SSH_HOME"
if [[ -f "$SSH_HOME/known_hosts" ]]; then
    sort -u "$KNOWN_HOSTS" "$SSH_HOME/known_hosts" -o "$SSH_HOME/known_hosts.new"
    mv "$SSH_HOME/known_hosts.new" "$SSH_HOME/known_hosts"
else
    install -m 0600 "$KNOWN_HOSTS" "$SSH_HOME/known_hosts"
fi
# An ssh_config Host entry pins the identity for nas connections
# without polluting the global IdentityFile defaults.
CFG_MARK="# preimpermanence-backup: ${NAS_HOST}"
if ! grep -qF "$CFG_MARK" "$SSH_HOME/config" 2>/dev/null; then
    {
        echo ""
        echo "$CFG_MARK"
        echo "Host ${NAS_HOST}"
        echo "    User ${NAS_USER}"
        echo "    Port ${NAS_PORT}"
        echo "    IdentityFile ${SSH_KEY}"
        echo "    IdentitiesOnly yes"
        echo "    StrictHostKeyChecking yes"
        echo "    BatchMode yes"
    } >>"$SSH_HOME/config"
    chmod 0600 "$SSH_HOME/config"
fi

export RESTIC_REPOSITORY="$REPO_URL"
export RESTIC_PASSWORD_FILE="$REPO_PASS_FILE"

echo "==> restic repo: $REPO_URL"

# -- init repo if needed -----------------------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
    echo "    [dry-run] would check / restic init repo"
else
    if restic snapshots >/dev/null 2>&1; then
        echo "    repo already initialized."
    else
        echo "==> restic init"
        restic init
    fi
fi

# -- enumerate normal users + their homes ------------------------------

declare -a user_homes=()
declare -a user_logins=()
while IFS=: read -r login _ uid _ _ home _; do
    if [[ "$uid" -ge 1000 && "$uid" -lt 65534 && -d "$home" && "$home" != "/var/empty" ]]; then
        user_logins+=("$login")
        user_homes+=("$home")
    fi
done </etc/passwd

echo "==> normal users detected: ${user_logins[*]:-<none>}"

# -- assemble paths to back up -----------------------------------------

declare -a paths=()
add_if_exists() { [[ -e "$1" ]] && paths+=("$1") || true; }

# System paths — mirrors flake-modules/impermanence.nix:295-351
for p in \
    /etc/NetworkManager/system-connections \
    /etc/machine-id \
    /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub \
    /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub \
    /var/lib/bluetooth \
    /var/lib/fprint \
    /var/lib/iwd \
    /var/lib/upower \
    /var/lib/colord \
    /var/lib/power-profiles-daemon \
    /var/lib/tpm2-tss \
    /var/lib/systemd \
    /var/lib/nixos \
    /var/log \
    /var/db/sudo/lectured \
    /root \
    ; do
    add_if_exists "$p"
done

# Per-user homes
for h in "${user_homes[@]}"; do
    paths+=("$h")
done

# Extras
for p in "${EXTRA_PATHS[@]}"; do
    paths+=("$p")
done

# -- exclude file ------------------------------------------------------

EXCLUDE_FILE=$(mktemp)
trap 'rm -f "$EXCLUDE_FILE"' EXIT

cat >"$EXCLUDE_FILE" <<'EOF'
# Junk excludes for per-user home backup. Aggressive (per operator
# preference); whole home minus these patterns.
.cache
.local/share/Trash
.local/share/baloo
.local/state
.npm
.cargo/registry
.rustup
.go/pkg
.gradle/caches
.m2/repository
go/pkg
node_modules
.venv
__pycache__
*.pyc
snap
.mozilla/firefox/*/Cache*
.mozilla/firefox/*/cache2
.mozilla/firefox/*/Crash Reports
.mozilla/firefox/*/storage/default/*/cache
.config/google-chrome/*/Cache
.config/google-chrome/*/Code Cache
.config/google-chrome/*/Service Worker
.config/google-chrome/Crashpad
.config/chromium/*/Cache
.config/chromium/*/Code Cache
.config/chromium/Crashpad
.config/BraveSoftware/*/*/Cache
.config/Code/Cache
.config/Code/CachedData
.config/Code/CachedExtensions
.config/Code/User/workspaceStorage
.config/Code/logs
.thumbnails
.gnupg/*.lock
.gnupg/random_seed
.gnupg/S.*
.dbus
.steam/steam/logs
.steam/steam/dumps
EOF

for ex in "${EXTRA_EXCLUDES[@]}"; do
    printf '%s\n' "$ex" >>"$EXCLUDE_FILE"
done

# -- size estimate -----------------------------------------------------

echo "==> estimating source size (du, may take a moment)..."
TOTAL_KB=$(du -sxk "${paths[@]}" 2>/dev/null | awk '{s+=$1} END {print s+0}')
TOTAL_MB=$(( TOTAL_KB / 1024 ))
echo "    ~${TOTAL_MB} MiB across ${#paths[@]} paths (pre-exclude, pre-dedup)."

# -- backup ------------------------------------------------------------

TAG_DATE="preimpermanence-$(date +%Y%m%d-%H%M%S)"
declare -a backup_args=(
    backup
    --tag preimpermanence
    --tag "$TAG_DATE"
    --host "$HOSTNAME_USED"
    --exclude-file "$EXCLUDE_FILE"
    --exclude-caches
    --one-file-system
)
# When stdout is not a TTY (e.g. piped through nix shell + sudo,
# captured to a log file, run via a tool that proxies output) restic
# falls back to printing every status update on its own line — which
# for ~9k files generates megabytes of noise. RESTIC_PROGRESS_FPS=0
# disables the periodic progress prints; the final summary
# ("Files: X new ... snapshot Z saved") still appears.
if [[ ! -t 1 ]]; then
    export RESTIC_PROGRESS_FPS=0
fi
backup_args+=("${paths[@]}")

echo "==> restic backup (tag: preimpermanence, $TAG_DATE)"
echo "    paths:"
printf '      %s\n' "${paths[@]}"

if [[ $DRY_RUN -eq 1 ]]; then
    echo "    [dry-run] would run: restic ${backup_args[*]}"
else
    restic "${backup_args[@]}"
fi

# -- summary banner ----------------------------------------------------

cat <<EOF

===============================================================================
   PRE-IMPERMANENCE BACKUP COMPLETE — STASH THESE SECRETS OFF-HOST NOW
===============================================================================

Host:          $HOSTNAME_USED
Repo URL:      $REPO_URL
Repo password: (contents of $REPO_PASS_FILE)
SSH key:       $SSH_KEY  (private; needed to push subsequent backups)
SSH pubkey:    $SSH_PUB

These files live under $STATE_DIR. They will be DESTROYED when you
re-egghead this host. To use them on the new install:

  1. Copy $REPO_PASS_FILE and $SSH_KEY off-box now (password manager
     or a USB stick) — there is no way to recover snapshots without
     the password.
  2. Run egghead with IS_REINSTALL=yes. Paste the password when
     prompted. Paste the SSH key contents into the new install's
     /persist/etc/ssh-restic/restic_ed25519 (the install script
     prompts for this too).
  3. After first boot, run preimpermanence-restore.sh to pull the
     latest preimpermanence snapshot into /persist.

The contents of the password and the pubkey, for convenience:

--- RESTIC REPO PASSWORD ---
$(cat "$REPO_PASS_FILE")
--- END ---

--- NAS SSH PUBKEY (already installed on NAS) ---
$(cat "$SSH_PUB")
--- END ---

EOF
