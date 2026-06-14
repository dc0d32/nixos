# backup — declarative restic backup to a TrueNAS (or any SFTP/SSH
# target) for the whole host. One repo per host, covering both system
# state (/persist) and every declared normal user's ~/persist. Source
# snapshots via btrfs read-only subvol snapshots for consistency
# during the backup window.
#
# Why restic over SFTP rather than btrbk / borgbackup / duplicati:
#
#   * btrbk / btrfs send-receive needs btrfs on the destination.
#     TrueNAS is ZFS at the pool level; sending btrfs streams onto a
#     ZFS dataset would just dump opaque blobs. No dedup, no
#     incremental restore granularity, no useful retention. Loses
#     most of btrbk's value.
#
#   * borg over SSH would also work but the borg binary needs to be
#     installed on the destination ("borg serve"). On TrueNAS that
#     means a Custom App or plugin — more setup than the operator
#     wants for a personal NAS.
#
#   * Duplicati needs a running daemon on each backed-up host (full
#     web UI + service), stores credentials in its own DB, and the
#     historical reliability of its restore path has been the source
#     of multiple user-side data-loss reports.
#
#   * restic over SFTP: only needs SSH + an unprivileged user on the
#     destination (zero NAS-side install). Dedup + encrypt + retention
#     all client-side. nixpkgs already ships `services.restic.backups.*`
#     which builds the systemd timer + service + the network-online
#     wait. We add a thin layer for the btrfs-snapshot consistency
#     wrapper, the AC-power gate, and a restore wrapper for seeding
#     and post-rebuild recovery.
#
# Why ONE repo per host (not one per user):
#
#   * Restic dedup is repo-scoped: splitting by user repays storage
#     for files two users share (caches, etc.).
#   * Per-domain restore granularity is preserved via restic --tag
#     (`system` vs `user-<login>`) and --include paths.
#   * Cross-host isolation is total — every host's repo is at a
#     hostname-specific path and uses its own password. The SHARED
#     `restic-backup` SSH user on the NAS can READ every repo path,
#     but only a host that knows the matching password can decrypt
#     any data. That shared user is what enables cross-host seeding
#     (a new host pulls another host's repo with the OTHER repo's
#     password — operator pastes it during install).
#
# Endpoint-spoofing defense:
#
#   * `backup.knownHostsFile` pins the destination's SSH host key.
#     The ssh restic invokes runs with StrictHostKeyChecking=yes +
#     BatchMode=yes. If the laptop is on a network that resolves
#     nas.lan to an attacker, ssh refuses the handshake → no
#     credential or data leak. (The repo password is symmetric and
#     never sent over wire anyway.)
#
# Wake-from-sleep behavior:
#
#   * Timer is daily at 03:00 with Persistent=true — systemd catches
#     missed runs on wake. NOT WakeSystem=true; laptop in a bag does
#     not get yanked out of S3.
#   * Service ExecStartPre polls /sys/class/power_supply/AC* for up
#     to 4h with 60s sleep. No AC → exit non-zero → next timer fire
#     retries.
#
# Restore + cross-host seeding workflow:
#
#   * The `backup-restore` wrapper (installed system-wide by this
#     module) handles both. Without args: restore latest snapshot
#     from the host's own repo into / (covers /persist + every
#     home/*/persist). `--from-host <other> --password-file <p>`:
#     pull from a different host's repo (seeding). `--include <p>`:
#     selective restore.
#   * Egghead surfaces a per-user seeding step that drops the right
#     wrapper invocations into the install script post-nixos-install.
#     See scripts/host-setup.sh + scripts/egghead.sh.
#
# Cross-module signal pattern:
#
#   options.backup.enable is declared INSIDE the NixOS module so it's
#   a per-NixOS-config signal (per the corrected understanding noted
#   in flake-modules/impermanence.nix). Hosts that import this module
#   publish backup.enable = true; hosts that don't see it as false.
#
# Retire when:
#   * NixOS upstream gains a richer first-class backup option, OR
#   * The operator switches to btrfs-send-receive against a btrfs NAS,
#     OR moves to a SaaS backup product (Backblaze B2, etc.). The
#     SFTP-specific parts would go but the AC-gate, btrfs-snapshot
#     wrapper, and seeding helpers all carry over.
{ ... }:
{
  flake.modules.nixos.backup = { lib, pkgs, config, ... }:
    let
      cfg = config.backup;
      hostname = config.networking.hostName;
      repoUrl = "sftp://${cfg.truenasUser}@${cfg.truenasHost}:${cfg.repoBasePath}/${hostname}";

      # Every normal user (UID >= 1000, isNormalUser = true). The
      # canonical NixOS way to enumerate real human accounts — works
      # on single-user (pb-x1) AND multi-user (m-pc, ah-1) hosts
      # identically. Hosts that want to exclude a user can set
      # backup.userExcludes (TODO if/when actually needed).
      normalUsers = lib.filterAttrs (_: u: u.isNormalUser) config.users.users;

      # SSH command restic invokes for the SFTP transport.
      # known_hosts pin + StrictHostKeyChecking=yes is the
      # endpoint-spoofing defense; BatchMode=yes prevents an
      # interactive password prompt from blocking the systemd service
      # forever on auth failure.
      sshCommand = "ssh -i ${toString cfg.sshIdentityFile} -o UserKnownHostsFile=${toString cfg.knownHostsFile} -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=30";

      # AC-power gate. Polls common sysfs nodes for "online=1" up to
      # 4h with 60s sleep. No-AC → exit 1 → next timer fire retries.
      # Desktops without an AC node are treated as "always on mains".
      waitForAcScript = pkgs.writeShellApplication {
        name = "backup-wait-for-ac";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          set -euo pipefail
          ac_nodes=(/sys/class/power_supply/AC /sys/class/power_supply/ACAD /sys/class/power_supply/AC0 /sys/class/power_supply/ADP1)
          found_node=""
          for n in "''${ac_nodes[@]}"; do
            if [ -e "$n/online" ]; then
              found_node="$n"
              break
            fi
          done
          if [ -z "$found_node" ]; then
            echo "backup-wait-for-ac: no AC sysfs node found; assuming desktop, proceeding."
            exit 0
          fi
          echo "backup-wait-for-ac: monitoring $found_node/online"
          deadline=$(( $(date +%s) + 4 * 3600 ))
          while [ "$(date +%s)" -lt "$deadline" ]; do
            if [ "$(cat "$found_node/online")" = "1" ]; then
              echo "backup-wait-for-ac: AC online, proceeding."
              exit 0
            fi
            sleep 60
          done
          echo "backup-wait-for-ac: AC not present after 4h, aborting (next timer fire will retry)." >&2
          exit 1
        '';
      };

      # btrfs RO snapshot wrapper. Runs in backupPrepareCommand /
      # backupCleanupCommand. Snapshot is mounted at
      # /run/restic-snapshots/persist. The restic `paths` list points
      # there instead of the live subvol, giving restic a consistent
      # point-in-time view even if a user is actively writing during
      # the backup. We only need to snapshot `persist` because the
      # impermanence NixOS module routes ALL persisted state
      # (system + every user's home) into /persist; /home itself
      # holds only ephemeral / bind-mounted views.
      snapshotPrepare = ''
        set -e
        mkdir -p /run/restic-snapshots
        ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot -r /persist /run/restic-snapshots/persist || true
      '';
      snapshotCleanup = ''
        ${pkgs.btrfs-progs}/bin/btrfs subvolume delete /run/restic-snapshots/persist || true
      '';

      # System + per-user persistence both live under /persist (system
      # at /persist/var/..., users at /persist/home/<login>/...). One
      # snapshot path covers both.
      backupPaths = [ "/run/restic-snapshots/persist" ] ++ cfg.extraSystemPaths;

      # Restore + seeding wrapper. Single binary covering:
      #   * `backup-restore`                  — latest from this host's repo, all paths.
      #   * `backup-restore --include /path`  — selective restore.
      #   * `backup-restore --from-host <h> --password-file <f>`
      #                                       — cross-host seeding / disaster recovery.
      #   * `backup-restore --snapshot <id>`  — pin to a specific snapshot.
      #   * `backup-restore --target /alt`    — restore under a different root (default /).
      #   * `backup-restore --seed-from-user <login>`
      #                                       — when seeding, take /persist/home/<login>
      #                                         from the source repo and write it under
      #                                         the destination's first normal user (or
      #                                         --seed-to-user). System-side /persist
      #                                         is NOT touched.
      #
      # In-repo paths look like /run/restic-snapshots/persist/... — the
      # wrapper maps a "natural" path the operator typed (/persist,
      # /persist/home/p) back to the in-repo path, runs restic restore
      # to a stage dir, then rsyncs the snapshot prefix back to the
      # real target path.
      restoreScript = pkgs.writeShellApplication {
        name = "backup-restore";
        runtimeInputs = [ pkgs.restic pkgs.rsync pkgs.coreutils pkgs.openssh ];
        text = ''
          set -euo pipefail

          FROM_HOST="${hostname}"
          PASSWORD_FILE="${toString cfg.passwordFile}"
          SNAPSHOT="latest"
          TARGET="/"
          INCLUDES=()
          DRY_RUN=0
          SEED_FROM_USER=""
          SEED_TO_USER=""

          while [ $# -gt 0 ]; do
            case "$1" in
              --from-host) FROM_HOST="$2"; shift 2;;
              --password-file) PASSWORD_FILE="$2"; shift 2;;
              --snapshot) SNAPSHOT="$2"; shift 2;;
              --target) TARGET="$2"; shift 2;;
              --include) INCLUDES+=("$2"); shift 2;;
              --dry-run) DRY_RUN=1; shift;;
              --seed-from-user) SEED_FROM_USER="$2"; shift 2;;
              --seed-to-user) SEED_TO_USER="$2"; shift 2;;
              -h|--help)
                cat <<EOF
          backup-restore — restore from this host's restic repo (or seed from another).

          Usage:
            sudo backup-restore                              Restore latest snapshot, all paths.
            sudo backup-restore --include /persist           Restore only /persist.
            sudo backup-restore --include /persist/home/p    Restore only one user's persisted state.
            sudo backup-restore --from-host pb-x1 \\
                                --password-file /tmp/pb-x1.pass \\
                                --seed-from-user p --seed-to-user alice
                                                             Seed alice's home on this host from
                                                             pb-x1's repo, sourced from user p
                                                             on that host.
            sudo backup-restore --snapshot abc123            Pin to a specific snapshot id.
            sudo backup-restore --target /alt                Restore under an alternate root.
            sudo backup-restore --dry-run                    Print what would happen.
          EOF
                exit 0;;
              *) echo "unknown arg: $1" >&2; exit 2;;
            esac
          done

          export RESTIC_REPOSITORY="sftp://${cfg.truenasUser}@${cfg.truenasHost}:${cfg.repoBasePath}/$FROM_HOST"
          export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"
          export RESTIC_PROGRESS_FPS=1
          SSH_CMD="${sshCommand}"

          # Seeding mode: --seed-from-user shortcut. Narrows INCLUDES
          # to /persist/home/<from> in the source repo and rewrites
          # the destination path to /persist/home/<to> (so a user
          # named "p" on pb-x1 can seed user "alice" on a fresh host).
          if [ -n "$SEED_FROM_USER" ]; then
            if [ ''${#INCLUDES[@]} -ne 0 ]; then
              echo "--seed-from-user is incompatible with --include" >&2; exit 2
            fi
            INCLUDES=("/persist/home/$SEED_FROM_USER")
          fi

          if [ ''${#INCLUDES[@]} -eq 0 ]; then
            INCLUDES=("/run/restic-snapshots")
          fi

          STAGE=$(mktemp -d)
          trap 'rm -rf "$STAGE"' EXIT

          for inc in "''${INCLUDES[@]}"; do
            case "$inc" in
              /run/restic-snapshots*) RESTIC_INC="$inc";;
              /persist*) RESTIC_INC="/run/restic-snapshots/persist''${inc#/persist}";;
              *) echo "include path must start with /persist or /run/restic-snapshots; got: $inc" >&2; exit 2;;
            esac

            echo "Restoring $RESTIC_INC from snapshot $SNAPSHOT on host $FROM_HOST..."
            if [ "$DRY_RUN" = "1" ]; then
              echo "(dry-run) would restic restore --include $RESTIC_INC --target $STAGE $SNAPSHOT"
              continue
            fi
            restic --option "sftp.command=$SSH_CMD %h" restore "$SNAPSHOT" \
              --include "$RESTIC_INC" --target "$STAGE"
          done

          # Map snapshot prefix back to real path and rsync into target.
          if [ -n "$SEED_FROM_USER" ]; then
            dest_user="''${SEED_TO_USER:-$SEED_FROM_USER}"
            src_dir="$STAGE/run/restic-snapshots/persist/home/$SEED_FROM_USER"
            dst_dir="$TARGET/persist/home/$dest_user"
            if [ ! -d "$src_dir" ]; then
              echo "seed: no source data under $src_dir; nothing to do" >&2
              exit 1
            fi
            echo "Seeding /persist/home/$SEED_FROM_USER → $dst_dir..."
            if [ "$DRY_RUN" = "1" ]; then
              rsync -aHAXn "$src_dir/" "$dst_dir/"
            else
              mkdir -p "$dst_dir"
              rsync -aHAX "$src_dir/" "$dst_dir/"
              if id "$dest_user" >/dev/null 2>&1; then
                chown -R "$dest_user:$(id -gn "$dest_user")" "$dst_dir"
              fi
            fi
          elif [ -d "$STAGE/run/restic-snapshots/persist" ]; then
            echo "Mapping /persist → $TARGET/persist..."
            if [ "$DRY_RUN" = "1" ]; then
              rsync -aHAXn "$STAGE/run/restic-snapshots/persist/" "$TARGET/persist/"
            else
              rsync -aHAX "$STAGE/run/restic-snapshots/persist/" "$TARGET/persist/"
            fi
          fi

          echo "Restore complete."
        '';
      };

      snapshotsScript = pkgs.writeShellApplication {
        name = "backup-snapshots";
        runtimeInputs = [ pkgs.restic pkgs.openssh ];
        text = ''
          set -euo pipefail
          export RESTIC_REPOSITORY="${repoUrl}"
          export RESTIC_PASSWORD_FILE="${toString cfg.passwordFile}"
          restic --option "sftp.command=${sshCommand} %h" snapshots "$@"
        '';
      };
    in
    {
      options.backup = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Master switch — when true, the importing host runs a
            daily restic backup of /persist + every normal user's
            ~/persist to the SFTP target. When false, the module is a
            no-op (the restic timer is not created, the SSH key +
            password files are not declared).

            Defaulted true so importing this module via a bundle
            actually does something. Opt out per-host by setting
            `backup.enable = false;` in the bridge.
          '';
        };
        truenasHost = lib.mkOption {
          type = lib.types.str;
          default = "nas.lan";
          description = ''
            Hostname of the SFTP/SSH endpoint. Must match the host
            key pinned in `backup.knownHostsFile`.
          '';
        };
        truenasUser = lib.mkOption {
          type = lib.types.str;
          default = "restic-backup";
          description = ''
            SFTP-only SSH user on the destination. Has read+write to
            this host's repo and read-only to other hosts' repos
            (enables cross-host seeding).
          '';
        };
        repoBasePath = lib.mkOption {
          type = lib.types.str;
          default = "/mnt/zrust/backup/restic";
          description = ''
            Absolute filesystem path on the destination under which
            each host's repo lives. Repo URL is
            `sftp://<user>@<host>:<repoBasePath>/<hostname>`.
          '';
        };
        sshIdentityFile = lib.mkOption {
          type = lib.types.path;
          default = "/persist/etc/ssh-restic/restic_ed25519";
          description = ''
            Per-host SSH private key restic uses for SFTP auth.
            Generated during install by host-setup.sh and stashed
            under /persist (survives root rollback). 0600 root.
          '';
        };
        knownHostsFile = lib.mkOption {
          type = lib.types.path;
          default = "/persist/etc/ssh-restic/restic_known_hosts";
          description = ''
            SSH known_hosts file with the destination host key
            pinned. Mismatched destination → handshake failure → no
            credential or data leak.
          '';
        };
        passwordFile = lib.mkOption {
          type = lib.types.path;
          default = "/persist/etc/restic/host.pass";
          description = ''
            Per-host repo password. Symmetric-encrypts every object
            client-side before it leaves the host, so even an
            attacker-controlled destination only ever sees
            ciphertext. Populated by host-setup.sh.
          '';
        };
        extraSystemPaths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Extra absolute paths to include alongside /persist.
            Sparingly — anything outside /persist is either ephemeral
            (wiped by impermanence) or under /home (already covered).
          '';
        };
        onCalendar = lib.mkOption {
          type = lib.types.str;
          default = "*-*-* 03:00:00";
          description = ''
            systemd OnCalendar spec for the daily backup timer.
            Persistent=true on the timer means missed runs (laptop
            suspended at 03:00) fire on next wake.
          '';
        };
        retentionDays = lib.mkOption {
          type = lib.types.int;
          default = 30;
          description = "Days to keep in restic's forget+prune pass.";
        };
        retentionWeeks = lib.mkOption {
          type = lib.types.int;
          default = 12;
          description = "Weeks to keep in restic's forget+prune pass.";
        };
        retentionMonths = lib.mkOption {
          type = lib.types.int;
          default = 12;
          description = "Months to keep in restic's forget+prune pass.";
        };
        retentionYears = lib.mkOption {
          type = lib.types.int;
          default = 3;
          description = "Years to keep in restic's forget+prune pass.";
        };
      };

      config = lib.mkIf cfg.enable {
        # services.restic.backups.<name> is the nixpkgs-shipped restic
        # helper. It builds a systemd timer + service with restic env
        # wired up, plus pruneOpts → a post-backup restic forget+prune.
        # We use one service named "host" covering both system and
        # user paths in one snapshot per timer fire; --tag preserves
        # per-domain restore granularity.
        services.restic.backups.host = {
          repository = repoUrl;
          passwordFile = toString cfg.passwordFile;

          paths = backupPaths;

          # `auto` tag distinguishes scheduled backups from any
          # ad-hoc ones an operator runs manually (which won't carry
          # this tag). nixpkgs' restic module doesn't have a `tags`
          # option, so we pass --tag through extraBackupArgs.
          extraBackupArgs = [ "--tag" "auto" ];

          backupPrepareCommand = snapshotPrepare;
          backupCleanupCommand = snapshotCleanup;

          # SSH transport details — sftp.command lets us inject the
          # full ssh command line including identity file + pinned
          # known_hosts.
          extraOptions = [
            "sftp.command=${sshCommand} %h"
          ];

          # forget+prune after every backup. Restic is fast and
          # prune-on-every-run keeps the repo lean.
          pruneOpts = [
            "--keep-daily ${toString cfg.retentionDays}"
            "--keep-weekly ${toString cfg.retentionWeeks}"
            "--keep-monthly ${toString cfg.retentionMonths}"
            "--keep-yearly ${toString cfg.retentionYears}"
          ];

          timerConfig = {
            OnCalendar = cfg.onCalendar;
            Persistent = true;
            RandomizedDelaySec = "30m";
          };

          # `initialize = true` makes restic create the repo on first
          # run if it doesn't exist yet. Safe for new installs; no-op
          # on a re-install that already has a repo at the URL.
          initialize = true;
        };

        # AC-gate + network-online wait on the restic-generated
        # service. The restic module sets up network-online itself,
        # but adding the dependencies again is idempotent and makes
        # the intent obvious.
        systemd.services.restic-backups-host = {
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          serviceConfig.ExecStartPre = [
            "${waitForAcScript}/bin/backup-wait-for-ac"
          ];
        };

        # Install the operator-facing wrappers system-wide.
        environment.systemPackages = [
          restoreScript
          snapshotsScript
          pkgs.restic
        ];
      };
    };
}
