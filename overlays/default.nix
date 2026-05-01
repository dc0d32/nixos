# Flake-wide overlays. Each overlay lives in its own file and MUST include:
#   1. A comment explaining *why* the override exists.
#   2. A retirement condition — the trigger that says it's safe to delete.
# Without (2), overlays accumulate forever and nobody remembers which are
# still needed. When nixpkgs catches up, delete the file and remove its
# entry from the list below.
#
# Consumed by:
#   - flake-modules/nix-settings.nix (sets `nixpkgs.overlays` system-wide).
#   - Each host bridge's `mkPkgs` factory (HM-side pkgs instance).
[
  (import ./nvim-treesitter-pin.nix)
  (import ./idled.nix)
]
