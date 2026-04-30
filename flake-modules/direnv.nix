# direnv — auto-load per-directory env (with nix-direnv for `use flake`).
# Wired into zsh integration; if zsh is disabled the integration is a no-op.
#
# Migrated from modules/home/direnv.nix.
{
  flake.modules.homeManager.direnv = {
    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
      enableZshIntegration = true;
    };
  };
}
