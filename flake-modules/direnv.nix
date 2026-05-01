# direnv — auto-load per-directory env (with nix-direnv for `use flake`).
# Wired into zsh integration; if zsh is disabled the integration is a no-op.
#
# Retire when: direnv / nix-direnv is no longer used to drive per-project
#   shells, or replaced by a different env-loader (e.g. mise, devenv's
#   own activation).
{
  flake.modules.homeManager.direnv = {
    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
      enableZshIntegration = true;
    };
  };
}
