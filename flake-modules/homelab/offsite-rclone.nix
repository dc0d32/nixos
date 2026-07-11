# offsite-rclone.nix — plain (unencrypted) rclone cloud mirrors for the
# homelab.
#
# Why this exists:
#   Some precious datasets (the immich originals *library*) want a plain,
#   browsable, incremental mirror to object storage rather than an encrypted
#   restic repo — so the files are viewable in the cloud provider's web UI
#   and a pre-existing rclone mirror (this homelab's was created by TrueNAS
#   cloud-sync, which is itself rclone under the hood) keeps accreting
#   incrementally instead of forcing a fresh full re-upload. Hosts declare
#     homelab.offsiteSync.<name> = {
#       source = "/mnt/zrust/vault/immich/library";
#       remote = ":azureblob:immich-library";   # rclone on-the-fly remote
#     };
#   The Azure account/key live in an env file under `homelab.secrets.dir`
#   (RCLONE_AZUREBLOB_ACCOUNT / RCLONE_AZUREBLOB_KEY) — never in the store,
#   never in git.
#
#   This is deliberately the *unencrypted* sibling of offsite-restic: use
#   restic when you want a site-loss-proof encrypted repo; use this when you
#   want the raw files browsable in the portal and byte-compatible with an
#   existing rclone mirror.
#
# Safety:
#   `rclone sync` mirrors deletions. If the source directory were missing or
#   empty (e.g. the backing ZFS pool failed to import) a naive sync would
#   MIRROR-DELETE the entire remote container. The generated unit therefore
#   refuses to run unless the source exists and is non-empty.
#
# Inert until `homelab.offsiteSync` is non-empty.
#
# Retire when: the homelab drops plain cloud mirrors in favour of restic-only.
{ ... }:
{
  flake.modules.nixos.offsite-rclone = { config, lib, pkgs, ... }:
    let
      cfg = config.homelab.offsiteSync;
      secretsDir = config.homelab.secrets.dir;
    in
    {
      options.homelab.offsiteSync = lib.mkOption {
        default = { };
        description = "Plain (unencrypted) rclone cloud mirrors, keyed by name.";
        example = {
          immich-library = {
            source = "/mnt/zrust/vault/immich/library";
            remote = ":azureblob:immich-library";
          };
        };
        type = lib.types.attrsOf (lib.types.submodule (_: {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              description = "Local source directory to mirror.";
            };
            remote = lib.mkOption {
              type = lib.types.str;
              example = ":azureblob:immich-library";
              description = ''
                rclone destination (remote:container). Use an on-the-fly
                remote like `:azureblob:<container>` so the backend creds come
                from `environmentFile` (RCLONE_AZUREBLOB_ACCOUNT / _KEY) with
                no rclone.conf in the store.
              '';
            };
            environmentFile = lib.mkOption {
              type = lib.types.str;
              default = "${secretsDir}/rclone-azure.env";
              description = ''
                env file exporting rclone backend creds, e.g.
                RCLONE_AZUREBLOB_ACCOUNT / RCLONE_AZUREBLOB_KEY.
              '';
            };
            schedule = lib.mkOption {
              type = lib.types.str;
              default = "*-*-* 00:00:00";
              description = "systemd OnCalendar for the sync timer.";
            };
            delete = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Mirror deletions with rclone `sync` (matches TrueNAS SYNC
                mode). Set false for additive `copy` (remote-only files are
                never removed).
              '';
            };
            after = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "zrust-import.service" ];
              description = "Extra units to order the sync after.";
            };
            extraArgs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "--fast-list" "--transfers=8" "--checkers=16" ];
              description = "rclone flags for the transfer.";
            };
          };
        }));
      };

      config = lib.mkIf (cfg != { }) {
        systemd.services = lib.mapAttrs'
          (name: s: lib.nameValuePair "offsite-sync-${name}" {
            description = "rclone offsite mirror: ${name} → ${s.remote}";
            after = [ "network-online.target" ] ++ s.after;
            wants = [ "network-online.target" ];
            serviceConfig = {
              Type = "oneshot";
              EnvironmentFile = s.environmentFile;
              # rclone resolves its config dir from $HOME; without it, it
              # shells out to `getent` (absent from the unit PATH) and warns
              # about defaulting to CWD. Pin HOME + an ephemeral config path
              # (the remote's creds come from EnvironmentFile, so no config
              # file is ever needed/written).
              Environment = [
                "HOME=/root"
                "RCLONE_CONFIG=/run/offsite-sync-${name}/rclone.conf"
              ];
              RuntimeDirectory = "offsite-sync-${name}";
              # Runs as root so it can read files owned by container uids under
              # the source tree (same as services.restic.backups).
              Nice = 10;
              IOSchedulingClass = "idle";
            };
            # Safety gate: never sync an empty/missing source — with mirror
            # semantics that would delete the entire remote container.
            script = ''
              set -euo pipefail
              src=${lib.escapeShellArg s.source}
              if [ ! -d "$src" ] || [ -z "$(${pkgs.coreutils}/bin/ls -A "$src" 2>/dev/null)" ]; then
                echo "offsite-sync ${name}: source $src missing or empty — refusing to sync (would mirror-delete the remote)." >&2
                exit 1
              fi
              exec ${pkgs.rclone}/bin/rclone ${if s.delete then "sync" else "copy"} \
                "$src" ${lib.escapeShellArg s.remote} \
                ${lib.escapeShellArgs s.extraArgs}
            '';
          })
          cfg;

        systemd.timers = lib.mapAttrs'
          (name: s: lib.nameValuePair "offsite-sync-${name}" {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = s.schedule;
              Persistent = true;
              RandomizedDelaySec = "15m";
            };
          })
          cfg;
      };
    };
}
