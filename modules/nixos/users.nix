{ variables, pkgs, ... }: {
  # User is declared in hosts/<h>/configuration.nix; this module is a placeholder
  # for cross-host user defaults (groups, shell, etc.) that shouldn't be repeated.
  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;
}
