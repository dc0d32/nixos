# Cross-host user defaults: enable zsh system-wide and pick it as the
# default user shell.
#
# The actual `users.users.<name>` declaration lives in each host's
# hosts/<h>/configuration.nix (until that file collapses into the host
# module too).
#
# Pattern A: hosts opt in by importing this module.
#
# Migrated from modules/nixos/users.nix.
{ ... }:
{
  flake.modules.nixos.users = { lib, pkgs, ... }: {
    programs.zsh.enable = lib.mkDefault true;
    # Plain value (priority 100) so we beat nixpkgs' bash module,
    # which sets users.defaultUserShell = mkDefault pkgs.bashInteractive
    # (priority 1000). Two mkDefaults would collide; a plain value
    # wins cleanly. Hosts that want a different default shell can
    # still override with lib.mkForce.
    users.defaultUserShell = pkgs.zsh;
  };
}
