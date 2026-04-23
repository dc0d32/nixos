{ variables, pkgs, lib, ... }: {
  # User is declared in hosts/<h>/configuration.nix; this module is a placeholder
  # for cross-host user defaults (groups, shell, etc.) that shouldn't be repeated.
  # mkDefault so hosts / WSL fork can override.
  programs.zsh.enable = lib.mkDefault true;
  users.defaultUserShell = lib.mkDefault pkgs.zsh;
}
