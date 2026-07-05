# secrets.nix — file-based secret convention for homelab hosts (no
# sops/agenix framework).
#
# Why this exists:
#   The user deliberately does NOT use a secrets framework (sops-nix/agenix
#   have failed to set up before). Instead, secrets live as
#   permission-restricted files on the impermanence `/persist` volume,
#   referenced by path — never in the Nix store, never in git. This module
#   just standardizes WHERE they live and (optionally) checks they're
#   present + not world-readable at activation. Other modules read
#   `config.homelab.secrets.dir` and point systemd `EnvironmentFile=` /
#   compose `env_file` at `${dir}/<name>`.
#
# Retire when:
#   * The homelab adopts a real secrets framework (would replace this), OR
#   * NixOS gains a blessed out-of-store secret primitive everyone uses.
{ ... }:
{
  flake.modules.nixos.secrets = { config, lib, ... }:
    let
      cfg = config.homelab.secrets;
    in
    {
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
      };

      config = lib.mkIf (cfg.required != [ ]) {
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
      };
    };
}
