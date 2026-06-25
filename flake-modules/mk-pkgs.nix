# Shared `pkgs` factory for host bridges.
#
# Every host bridge (pb-x1, pb-t480, wsl, ah-1) needs an
# `import inputs.nixpkgs { … }` instance with this repo's overlays and
# config (allowUnfree for chrome/vscode/etc., allowAliases = false to
# silence transitive deprecation warnings on pinned nixpkgs).
#
# The factory used to be inlined verbatim in each host bridge — four
# identical 7-line blocks. This module publishes it once on
# `flake.lib.mkPkgs`, so each host writes:
#
#     pkgs = config.flake.lib.mkPkgs system;
#
# instead of carrying its own copy. Adding a new overlay or flipping
# `allowAliases` is now a single-file edit.
#
# Retire when: nixpkgs ships a built-in mechanism for declaring a
#   per-flake default `pkgs` instance with overlays pre-applied, OR
#   every host bridge moves to a different way of constructing pkgs
#   (e.g. flake-parts' `withSystem` + perSystem `_module.args.pkgs`).
{ inputs, ... }:
{
  flake.lib.mkPkgs = system: import inputs.nixpkgs {
    inherit system;
    overlays = import ../overlays;
    config = {
      allowUnfree = true;
      allowAliases = false;
      # electron 39 is EOL on the 26.05 stable channel, but a few desktop
      # apps (e.g. bitwarden-desktop) still pin it. Allow it so the adult
      # desktop closure evaluates/builds. Mirror of the NixOS-side allow
      # in flake-modules/nix-settings.nix. Revisit when those apps move to
      # a supported electron (then drop this) — see the stable-migration
      # session log.
      permittedInsecurePackages = [ "electron-39.8.10" ];
    };
  };
}
