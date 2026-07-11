# backup — declarative restic backup to a TrueNAS (or any SFTP/SSH
# target) for the whole host. One repo per host, covering /persist
# (which under impermanence is the only place real state lives).
# btrfs RO snapshot of /persist for source-side consistency during
# the backup window.
#
# Why restic over SFTP: zero NAS-side install (SSH + an unprivileged
# user is all that's needed), client-side dedup/encrypt/retention,
# nixpkgs ships services.restic.backups.*. This module adds the
# btrfs snapshot wrapper, the AC-power gate, and a small
# `backup-restore` wrapper that maps the snapshot path back to
# /persist on restore.
#
# Cross-host seeding (restoring user state from another host's repo
# into this host's /persist/home/<login>) lives OUT of this module
# in scripts/seed-from-host.sh — it's a one-shot operator action,
# not a recurring service.
#
# Endpoint-spoofing defense: knownHostsFile pins the destination's
# SSH host key. ssh runs with StrictHostKeyChecking=yes +
# BatchMode=yes. Rogue nas.lan → handshake fails → no leak.
# Repo password symmetric-encrypts every object client-side, so
# even ciphertext at an attacker is useless.
#
# Wake-from-sleep: timer daily at 03:00 with Persistent=true (missed
# runs fire on next wake). Service ExecStartPre polls
# /sys/class/power_supply/AC* for up to 4h; no AC → exit → retry
# next timer fire. No WakeSystem (laptop in bag stays asleep).
#
# Per-host bootstrap is scripts/init-backup.sh. The TrueNAS-side
# one-time setup recipe lives in docs/runbooks/truenas-restic.md.
#
# Retire when:
#   * NixOS upstream gains a richer first-class backup option, OR
#   * The operator moves to a SaaS backup product (Backblaze B2,
#     etc.). The AC-gate + btrfs-snapshot wrappers carry over;
#     the SFTP-specific parts go.
{ ... }:
{
  flake.modules.nixos.backup = { lib, pkgs, config, ... }:
    let
      cfg = config.backup;
      hostname = config.networking.hostName;
      repoUrl = "sftp://${cfg.truenasUser}@${cfg.truenasHost}:${cfg.repoBasePath}/${hostname}";

      sshCommand = "ssh -i ${toString cfg.sshIdentityFile} -o UserKnownHostsFile=${toString cfg.knownHostsFile} -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=30";

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

      # Snapshot /persist read-only at /run/restic-snapshots/persist
      # so restic sees a consistent point-in-time even if a user is
      # actively writing. Impermanence routes every persisted bit
      # through /persist, so one snapshot covers system + all users.
      snapshotPrepare = ''
        set -e
        mkdir -p /run/restic-snapshots
        ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot -r /persist /run/restic-snapshots/persist || true
      '';
      snapshotCleanup = ''
        ${pkgs.btrfs-progs}/bin/btrfs subvolume delete /run/restic-snapshots/persist || true
      '';

      backupPaths = [ "/run/restic-snapshots/persist" ] ++ cfg.extraSystemPaths;

      # Restore wrapper. Defaults to "restore latest into /", but
      # supports --include for selective restore, --snapshot to pin
      # to a specific id, --target for an alternate root, --dry-run
      # to plan. Maps the snapshot-prefixed in-repo path
      # (/run/restic-snapshots/persist/…) back to /persist on
      # restore via rsync from a stage dir.
      restoreScript = pkgs.writeShellApplication {
        name = "backup-restore";
        runtimeInputs = [ pkgs.restic pkgs.rsync pkgs.coreutils pkgs.openssh ];
        text = ''
          set -euo pipefail

          SNAPSHOT="latest"
          TARGET="/"
          INCLUDES=()
          DRY_RUN=0

          while [ $# -gt 0 ]; do
            case "$1" in
              --snapshot) SNAPSHOT="$2"; shift 2;;
              --target) TARGET="$2"; shift 2;;
              --include) INCLUDES+=("$2"); shift 2;;
              --dry-run) DRY_RUN=1; shift;;
              -h|--help)
                cat <<EOF
          backup-restore — restore from this host's restic repo.

          Usage:
            sudo backup-restore                              Restore latest snapshot, all paths.
            sudo backup-restore --include /persist           Restore only /persist.
            sudo backup-restore --include /persist/home/p    Restore only one user's persisted state.
            sudo backup-restore --snapshot abc123            Pin to a specific snapshot id.
            sudo backup-restore --target /alt                Restore under an alternate root.
            sudo backup-restore --dry-run                    Print what would happen.

          To pull data FROM another host's repo (seeding a fresh install), use
          scripts/seed-from-host.sh instead.
          EOF
                exit 0;;
              *) echo "unknown arg: $1" >&2; exit 2;;
            esac
          done

          export RESTIC_REPOSITORY="${repoUrl}"
          export RESTIC_PASSWORD_FILE="${toString cfg.passwordFile}"
          export RESTIC_PROGRESS_FPS=1
          SSH_CMD="${sshCommand}"

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

            echo "Restoring $RESTIC_INC from snapshot $SNAPSHOT..."
            if [ "$DRY_RUN" = "1" ]; then
              echo "(dry-run) would restic restore --include $RESTIC_INC --target $STAGE $SNAPSHOT"
              continue
            fi
            restic --option "sftp.command=$SSH_CMD %h" restore "$SNAPSHOT" \
              --include "$RESTIC_INC" --target "$STAGE"
          done

          if [ -d "$STAGE/run/restic-snapshots/persist" ]; then
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
            daily restic backup of /persist to the SFTP target. When
            false, the module is a no-op (no timer, no SSH key
            assertions). Defaulted true so importing actually does
            something; opt out with `backup.enable = false;`.
          '';
        };
        truenasHost = lib.mkOption {
          type = lib.types.str;
          default = "andromeda.lan";
          description = ''
            Hostname of the SFTP/SSH endpoint. The homelab NAS is now
            bare-metal NixOS `andromeda` (post-TrueNAS migration);
            `andromeda.lan` resolves to it. (Was `nas.lan`, which pointed at
            the retired TrueNAS VM.)
          '';
        };
        truenasUser = lib.mkOption {
          type = lib.types.str;
          default = "restic-backup";
          description = "SFTP-only SSH user on the destination.";
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
            Generated post-install by scripts/init-backup.sh and
            stashed under /persist (survives root rollback). 0600 root.
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
            client-side before it leaves the host. Populated
            post-install by scripts/init-backup.sh (operator pastes
            from password manager).
          '';
        };
        extraSystemPaths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Extra absolute paths to include alongside /persist.
            Sparingly — anything outside /persist is either ephemeral
            (wiped by impermanence) or already covered.
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
        services.restic.backups.host = {
          repository = repoUrl;
          passwordFile = toString cfg.passwordFile;

          paths = backupPaths;

          extraBackupArgs = [ "--tag" "auto" ];

          backupPrepareCommand = snapshotPrepare;
          backupCleanupCommand = snapshotCleanup;

          extraOptions = [
            "sftp.command=${sshCommand} %h"
          ];

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

          initialize = true;
        };

        systemd.services.restic-backups-host = {
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          serviceConfig.ExecStartPre = [
            "${waitForAcScript}/bin/backup-wait-for-ac"
          ];
        };

        environment.systemPackages = [
          restoreScript
          snapshotsScript
          pkgs.restic
        ];
      };
    };
}
