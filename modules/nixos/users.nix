{ variables, pkgs, lib, ... }: {
  # User is declared in hosts/<h>/configuration.nix; this module is a placeholder
  # for cross-host user defaults (groups, shell, etc.) that shouldn't be repeated.
  programs.zsh.enable = lib.mkDefault true;
  # Plain value (priority 100) so we beat nixpkgs' bash module, which sets
  # users.defaultUserShell = mkDefault pkgs.bashInteractive (priority 1000).
  # Two mkDefaults would collide; a plain value wins cleanly. Hosts that want
  # a different default shell can still override with lib.mkForce.
  users.defaultUserShell = pkgs.zsh;
}
