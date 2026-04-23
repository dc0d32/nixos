{ inputs, lib, ... }: {
  # mkDefault on scalars so WSL fork / hosts override cleanly. Lists (like
  # experimental-features) merge automatically, no wrapper needed.
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
  # Drop backward-compat aliases so deprecated-rename warnings (e.g. the
  # recurring nvim-treesitter-legacy one) don't fire on every rebuild.
  # Pinned nixos-unstable: we deliberately update inputs and don't need
  # the shims.
  nixpkgs.config.allowAliases = lib.mkDefault false;
  # Apply the flake-wide overlays. See overlays/default.nix.
  nixpkgs.overlays = import ../../overlays;
}
