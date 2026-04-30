# laptop — primary dev machine (Lenovo X1 Yoga, x86_64-linux).
#
# DENDRITIC MIGRATION NOTE: this host module is currently a *bridge*
# between the new flake-parts substrate and the legacy
# ./modules/{nixos,home}/ tree. It absorbs what `lib/mkHost` and
# `lib/mkHome` used to do (read variables.nix, thread it through
# specialArgs, build a home-manager pkgs instance with overlays).
#
# As features migrate into ./flake-modules/<feature>.nix, the
# `imports` lists below shrink. When the legacy tree is empty:
#   - the `imports = [ ../../modules/nixos ];` line goes away
#   - the `imports = [ ../../modules/home ];` line goes away
#   - hosts/laptop/configuration.nix's responsibilities collapse into
#     this file
#   - hosts/laptop/variables.nix is deleted; its remaining values move
#     into option settings on the relevant feature modules below
#
# Until then, this file is intentionally a thin shim. Don't add
# feature config here — add a feature module under ./flake-modules/
# instead.
{ inputs, lib, ... }:
let
  hostName = "laptop";
  variables = import ../../hosts/laptop/variables.nix;
  userVariables = import (../../homes + "/p@laptop/variables.nix");

  system = variables.system or "x86_64-linux";

  hmVariables = variables // userVariables // {
    user = variables.user;
    hostname = hostName;
  };
  user = hmVariables.user;

  # HM pkgs instance. Mirrors the pre-dendritic mkHome:
  #   - apply repo-wide overlays (overlays/default.nix)
  #   - allowUnfree for chrome/vscode/etc.
  #   - allowAliases = false to silence transitive deprecation warnings
  #     (e.g. nvim-treesitter-legacy) on pinned nixos-unstable
  hmPkgs = import inputs.nixpkgs {
    inherit system;
    overlays = import ../../overlays;
    config = {
      allowUnfree = true;
      allowAliases = false;
    };
  };
in
{
  configurations.nixos.${hostName} = {
    specialArgs.variables = variables;
    module = {
      imports = [
        ../../modules/nixos
        ../../hosts/laptop/configuration.nix
      ];
    };
  };

  configurations.homeManager."${user}@${hostName}" = {
    pkgs = hmPkgs;
    extraSpecialArgs.variables = hmVariables;
    module = {
      imports = [
        ../../modules/home
        (../../homes + "/p@laptop/home.nix")
      ];

      home.username = user;
      home.homeDirectory =
        if lib.hasSuffix "darwin" system
        then "/Users/${user}"
        else "/home/${user}";
      home.stateVersion = hmVariables.stateVersion or "25.11";
    };
  };
}
