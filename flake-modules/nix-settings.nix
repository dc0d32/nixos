# Nix daemon settings — flakes + experimental commands, store
# optimisation, weekly GC, allowUnfree, allowAliases off, repo-wide
# overlays.
#
# Pattern A: hosts opt in by importing this module. WSL hosts may
# choose not to import (the upstream WSL fork manages a separate Nix
# config); on bare-metal hosts these defaults apply.
#
# All scalars use mkDefault so any host that *does* import this can
# still override individual knobs without mkForce. Lists (like
# experimental-features) merge automatically.
#
# allowAliases is set to false to silence deprecated-rename warnings
# (e.g. the recurring nvim-treesitter-legacy one) on every rebuild.
# Pinned nixos-unstable: we deliberately update inputs and don't need
# the shims.
#
# Migrated from modules/nixos/nix-settings.nix.
{ ... }:
{
  flake.modules.nixos.nix-settings = { lib, ... }: {
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = lib.mkDefault true;
      warn-dirty = lib.mkDefault false;
    };
    nix.gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault "weekly";
      options = lib.mkDefault "--delete-older-than 14d";
    };
    nixpkgs.config.allowUnfree = lib.mkDefault true;
    nixpkgs.config.allowAliases = lib.mkDefault false;
    # Apply the flake-wide overlays. See overlays/default.nix.
    nixpkgs.overlays = import ../overlays;
  };
}
