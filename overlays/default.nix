# Flake-wide overlays. Each overlay lives in its own file and MUST include:
#   1. A comment explaining *why* the override exists.
#   2. A retirement condition — the trigger that says it's safe to delete.
# Without (2), overlays accumulate forever and nobody remembers which are
# still needed. When nixpkgs catches up, delete the file and remove its
# entry from the list below.
#
# Consumed by:
#   - flake-modules/nix-settings.nix (sets `nixpkgs.overlays` system-wide).
#   - flake-modules/mk-pkgs.nix (the shared HM-side `pkgs` factory each
#     host bridge calls via `config.flake.lib.mkPkgs`).
[
  # EVDI 1.15.0: Linux 7.2 DRM API compatibility, pending the nixpkgs bump.
  # Retire when nixpkgs packages EVDI >= 1.15.0. See the file header.
  (import ./evdi.nix)

  # DisplayLink userspace driver: swap nixpkgs' `requireFile` source for a
  # `fetchurl`, so DisplayLink docks work on unattended installs/upgrades.
  # Retire when nixpkgs drops requireFile, or no host imports
  # flake.modules.nixos.displaylink. See the file header.
  (import ./displaylink.nix)

  # mermaid-ascii: not in nixpkgs, and the packaged alternative
  # (mermaid-cli) is a 2.1 GiB Chromium closure that only emits images
  # alacritty can't display. Used by md-view to render ```mermaid blocks.
  # Retire when nixpkgs packages it. See the file header.
  (import ./mermaid-ascii.nix)
]
