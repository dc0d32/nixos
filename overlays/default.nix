# Flake-wide overlays. Each overlay lives in its own file and MUST include:
#   1. A comment explaining *why* the override exists.
#   2. A retirement condition — the trigger that says it's safe to delete.
# Without (2), overlays accumulate forever and nobody remembers which are
# still needed. When nixpkgs catches up, delete the file and remove its
# entry from the list below.
#
# Consumed by:
#   - lib/default.nix (mkHome's pkgs instance)
#   - modules/nixos/nix-settings.nix (nixpkgs.overlays for NixOS systems)
[
  (import ./nvim-treesitter-pin.nix)
]
