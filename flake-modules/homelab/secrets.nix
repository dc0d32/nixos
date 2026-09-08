# secrets.nix — staged SOPS migration plus legacy file-secret compatibility.
#
# Why this exists:
#   Existing hosts consume permission-restricted files under `/persist`; they
#   must keep working while secrets move one trust boundary at a time into
#   SOPS-encrypted files. This module provides sops-nix with the host's
#   persistent SSH identity while retaining the old path/check interface until
#   every service has migrated.
#
# Retire when:
#   * Every consumer uses `sops.secrets` directly and the compatibility
#     `homelab.secrets.{dir,required}` options have no callers.
{ inputs, ... }:
{
  flake.modules.nixos.secrets = { config, lib, ... }:
    let
      cfg = config.homelab.secrets;
    in
    {
      imports = [ inputs.sops-nix.nixosModules.sops ];

      options.homelab.secrets = {
        dir = lib.mkOption {
          type = lib.types.str;
          default = "/persist/secrets";
          description = ''
            Directory holding out-of-store secret files (0600). Referenced
            by other modules as `''${config.homelab.secrets.dir}/<name>`.
          '';
        };
        required = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "cloudflare-token" "restic-azure.env" ];
          description = ''
            Secret filenames expected under `dir`. Checked (warn-only) at
            activation so a missing/loose-permission secret is visible in
            the switch log without bricking activation.
          '';
        };
        sopsFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            Host-specific SOPS file. Null preserves the legacy file-only mode;
            set this during that host's migration to enable unattended
            activation-time decryption via its persistent SSH host key.
          '';
        };
      };

      config = lib.mkMerge [
        (lib.mkIf (cfg.sopsFile != null) {
          sops.defaultSopsFile = cfg.sopsFile;
          sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        })

        (lib.mkIf (cfg.required != [ ]) {
          # Runs on the target at activation (NOT at eval — the files live on
          # the machine, not the build host). Warn-only: never block a switch.
          system.activationScripts.homelabSecretsCheck = ''
            for s in ${lib.escapeShellArgs cfg.required}; do
              f="${cfg.dir}/$s"
              if [ ! -e "$f" ]; then
                echo "homelab.secrets: WARNING missing secret $f" >&2
              elif [ "$(stat -c %a "$f" 2>/dev/null)" != "600" ]; then
                echo "homelab.secrets: WARNING $f is not mode 0600" >&2
              fi
            done
          '';
        })
      ];
    };
}
