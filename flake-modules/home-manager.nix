# Provides an option for declaring standalone home-manager configurations.
#
# Each entry under `configurations.homeManager.<name>` becomes
# `homeConfigurations.<name>` plus a `checks.<system>` entry pointing
# at the activation package, so `nix flake check` builds every HM
# config alongside its NixOS host.
#
# Standalone HM (as opposed to the HM NixOS module) requires an
# explicit `pkgs` instance because there is no `nixpkgs.hostPlatform`
# config option to infer one from. Each host module supplies its own
# `pkgs` (with the repo's overlays applied). The substrate just glues
# them together.
#
# No upstream dendritic example for this — modeled on
# ./nixos.nix and lib/default.nix's pre-dendritic mkHome.
#
# Safe to delete in the cleanup commit that completes the migration
# (i.e. when every HM module has been converted into a feature module
# under flake.modules.homeManager.<feature>).
{ lib, config, inputs, ... }:
{
  options.configurations.homeManager = lib.mkOption {
    type = lib.types.lazyAttrsOf (
      lib.types.submodule {
        options = {
          pkgs = lib.mkOption {
            type = lib.types.unspecified;
            description = "Nixpkgs instance to evaluate this HM config against.";
          };
          module = lib.mkOption {
            type = lib.types.deferredModule;
            description = "Top-level home-manager module for this configuration.";
          };
          extraSpecialArgs = lib.mkOption {
            type = lib.types.attrsOf lib.types.unspecified;
            default = { };
            description = ''
              Extra specialArgs to forward into home-manager modules.
              `inputs` is always added.
            '';
          };
        };
      }
    );
    default = { };
  };

  config.flake = {
    homeConfigurations = lib.flip lib.mapAttrs config.configurations.homeManager (
      _name: { pkgs, module, extraSpecialArgs }:
        inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = { inherit inputs; } // extraSpecialArgs;
          modules = [ module ];
        }
    );
  };

  config.perSystem = { system, ... }: {
    checks = lib.pipe config.flake.homeConfigurations [
      (lib.filterAttrs (_name: hm: hm.pkgs.stdenv.hostPlatform.system == system))
      (lib.mapAttrs' (name: hm: lib.nameValuePair "configurations:home-manager:${name}" hm.activationPackage))
    ];
  };
}
