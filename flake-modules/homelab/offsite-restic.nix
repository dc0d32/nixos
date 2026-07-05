# offsite-restic.nix — restic offsite backups (Azure Blob) for the homelab.
#
# Why this exists:
#   Restore tier 3: an offsite copy that survives site loss (today: the
#   immich library → Azure). Hosts declare `homelab.offsite.<name> = {
#   paths = […]; repository = "azure:<container>:/"; }`. Secrets (the repo
#   password + Azure account/key) live as files under
#   `config.homelab.secrets.dir` — never in the store.
#
# Inert until `homelab.offsite` is non-empty.
#
# Retire when: the homelab changes offsite provider/tooling.
{ ... }:
{
  flake.modules.nixos.offsite-restic = { config, lib, ... }:
    let
      cfg = config.homelab.offsite;
      secretsDir = config.homelab.secrets.dir;
    in
    {
      options.homelab.offsite = lib.mkOption {
        default = { };
        description = "restic offsite backups, keyed by name.";
        example = {
          immich-library = {
            paths = [ "/mnt/zrust/vault/immich/library" ];
            repository = "azure:immich-library:/";
          };
        };
        type = lib.types.attrsOf (lib.types.submodule (_: {
          options = {
            paths = lib.mkOption { type = lib.types.listOf lib.types.str; };
            repository = lib.mkOption {
              type = lib.types.str;
              example = "azure:immich-library:/";
              description = "restic repository URL (Azure backend).";
            };
            passwordFile = lib.mkOption {
              type = lib.types.str;
              default = "${secretsDir}/restic.pass";
              description = "restic repo password file (out-of-store).";
            };
            environmentFile = lib.mkOption {
              type = lib.types.str;
              default = "${secretsDir}/restic-azure.env";
              description = "env file with AZURE_ACCOUNT_NAME / _KEY.";
            };
            schedule = lib.mkOption {
              type = lib.types.str;
              default = "*-*-* 02:30:00";
              description = "systemd OnCalendar for the backup timer.";
            };
          };
        }));
      };

      config = lib.mkIf (cfg != { }) {
        services.restic.backups = lib.mapAttrs
          (_name: b: {
            inherit (b) paths repository passwordFile environmentFile;
            initialize = true;
            timerConfig = { OnCalendar = b.schedule; Persistent = true; };
            pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" ];
          })
          cfg;
      };
    };
}
