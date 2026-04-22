{ inputs, ... }:
let
  inherit (inputs) nixpkgs home-manager;
  lib = nixpkgs.lib;

  # Flake-wide overlay set. Applied to both the home-manager pkgs instance
  # and the NixOS pkgs via nixpkgs.overlays in modules/nixos/nix-settings.nix.
  overlays = [ (import ../overlays) ];

  # Directories that aren't hosts/homes (templates, hidden dirs)
  isRealEntry = name: type:
    type == "directory" && !(lib.hasPrefix "_" name) && !(lib.hasPrefix "." name);

  listDirs = path:
    lib.attrNames (lib.filterAttrs isRealEntry (builtins.readDir path));

  # Load a host's variables.nix if present, else {}
  loadVars = path:
    if builtins.pathExists (path + "/variables.nix")
    then import (path + "/variables.nix")
    else { };

  forAllSystems = f: lib.genAttrs
    [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]
    (system: f system);
in
rec {
  inherit forAllSystems listDirs loadVars overlays;

  # Build a NixOS system config for hosts/<hostname>/
  mkHost = { hostname, hostsDir, modulesDir }:
    let
      hostPath = hostsDir + "/${hostname}";
      variables = loadVars hostPath;
      system = variables.system or "x86_64-linux";
    in
    lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs variables hostname; };
      modules = [
        (modulesDir + "/nixos")
        (hostPath + "/configuration.nix")
      ];
    };

  # Build a standalone home-manager config for homes/<user>@<host>/
  mkHome = { name, homesDir, modulesDir, hostsDir }:
    let
      parts = lib.splitString "@" name;
      user = builtins.elemAt parts 0;
      hostname = builtins.elemAt parts 1;
      homePath = homesDir + "/${name}";
      # Pull variables from the matching host dir if it exists
      hostPath = hostsDir + "/${hostname}";
      variables = (loadVars hostPath) // (loadVars homePath) // {
        inherit user hostname;
      };
      system = variables.system or "x86_64-linux";
      pkgs = import inputs.nixpkgs {
        inherit system overlays;
        config = {
          allowUnfree = true;
          # Aliases are backward-compat shims kept behind deprecation
          # warnings. On pinned nixos-unstable we don't need the shims,
          # and disabling them silences noise like the recurring
          # `nvim-treesitter-legacy is deprecated` eval warning that
          # some transitive dependency pulls in.
          allowAliases = false;
        };
      };
    in
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = { inherit inputs variables; };
      modules = [
        (modulesDir + "/home")
        (homePath + "/home.nix")
        {
          home.username = user;
          home.homeDirectory =
            if lib.hasSuffix "darwin" system
            then "/Users/${user}"
            else "/home/${user}";
          home.stateVersion = variables.stateVersion or "25.11";
        }
      ];
    };

  # Build all nixosConfigurations by scanning hosts/
  mkAllHosts = { hostsDir, modulesDir }:
    lib.genAttrs (listDirs hostsDir) (hostname:
      mkHost { inherit hostname hostsDir modulesDir; });

  # Build all homeConfigurations by scanning homes/
  mkAllHomes = { homesDir, hostsDir, modulesDir }:
    lib.genAttrs (listDirs homesDir) (name:
      mkHome { inherit name homesDir hostsDir modulesDir; });
}
