{ inputs, ... }: {
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
    warn-dirty = false;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nixpkgs.config.allowUnfree = true;
  # Drop backward-compat aliases so deprecated-rename warnings (e.g. the
  # recurring nvim-treesitter-legacy one) don't fire on every rebuild.
  # Pinned nixos-unstable: we deliberately update inputs and don't need
  # the shims.
  nixpkgs.config.allowAliases = false;
  # Apply the flake-wide overlays. See overlays/default.nix.
  nixpkgs.overlays = import ../../overlays;
}
