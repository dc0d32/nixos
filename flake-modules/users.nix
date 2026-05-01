# Cross-host user defaults: enable zsh system-wide, pick it as the
# default user shell, and declare the per-NixOS-config `users.primary`
# option for other feature modules to reference.
#
# `users.primary` is a NixOS option (per-host), not a flake-parts
# option (per-flake). Each host bridge sets it inside its
# `configurations.nixos.<name>.module = { … };` block. Feature modules
# that need to know which user owns the box read the inner-config
# `config.users.primary` (e.g. flake-modules/hardware-hacking.nix,
# flake-modules/wsl.nix). This replaces the earlier flake-parts-level
# `host.user` singleton, which only worked because every host in the
# repo happened to use the same user.
#
# Pattern A: hosts opt in by importing this module. Currently every
# host does, because `users.defaultUserShell = pkgs.zsh` is a
# precondition for the rest of the modules to compose cleanly.
#
# Retire when: NixOS gains a first-class per-host "primary user"
#   option upstream, OR every consumer of users.primary is refactored
#   to look up the user some other way.
{ ... }:
{
  flake.modules.nixos.users = { lib, pkgs, ... }: {
    options.users.primary = lib.mkOption {
      type = lib.types.str;
      description = ''
        Primary human user account on this host. Read by feature
        modules that need to grant the user extra group memberships
        or set per-user defaults (e.g. flake-modules/wsl.nix's
        `wsl.defaultUser`, flake-modules/hardware-hacking.nix's
        `dialout`/`plugdev` group membership).

        Set per-host inside each host bridge's
        `configurations.nixos.<name>.module` block. Not declared with
        a default — leaving it unset is a configuration error.
      '';
    };

    config = {
      programs.zsh.enable = lib.mkDefault true;
      # Plain value (priority 100) so we beat nixpkgs' bash module,
      # which sets users.defaultUserShell = mkDefault pkgs.bashInteractive
      # (priority 1000). Two mkDefaults would collide; a plain value
      # wins cleanly. Hosts that want a different default shell can
      # still override with lib.mkForce.
      users.defaultUserShell = pkgs.zsh;
    };
  };
}
