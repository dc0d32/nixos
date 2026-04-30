# Provides an option for declaring NixOS configurations.
#
# Each entry under `configurations.nixos.<name>.module` becomes
# `nixosConfigurations.<name>` plus a `checks.<system>` entry pointing
# at the toplevel derivation, so `nix flake check` builds every host.
#
# Adapted from mightyiam/dendritic/example/modules/nixos.nix. The only
# additions over the upstream example:
#   - `specialArgs = { inherit inputs; }` so legacy modules under
#     ./modules/nixos/ can keep reading `inputs` from specialArgs
#     during the dendritic migration. Once every legacy module has
#     been migrated to a feature module that reads `config.flake`
#     directly, this can be dropped.
#   - A second `specialArgs.variables` slot, populated per-host inside
#     each ./flake-modules/hosts/<host>.nix, for the same migration
#     reason. To be removed in the same final cleanup commit.
#
# Safe to delete in the cleanup commit that completes the migration
# AND removes the last `specialArgs` reader.
{ lib, config, inputs, ... }:
{
  options.configurations.nixos = lib.mkOption {
    type = lib.types.lazyAttrsOf (
      lib.types.submodule {
        options = {
          module = lib.mkOption {
            type = lib.types.deferredModule;
          };
          specialArgs = lib.mkOption {
            type = lib.types.attrsOf lib.types.unspecified;
            default = { };
            description = ''
              Extra specialArgs to forward into NixOS modules.
              `inputs` is always added.
            '';
          };
        };
      }
    );
    default = { };
  };

  config.flake = {
    nixosConfigurations = lib.flip lib.mapAttrs config.configurations.nixos (
      _name: { module, specialArgs }: lib.nixosSystem {
        specialArgs = { inherit inputs; } // specialArgs;
        modules = [ module ];
      }
    );
  };

  config.perSystem = { system, ... }: {
    checks = lib.pipe config.flake.nixosConfigurations [
      (lib.filterAttrs (_name: nixos: nixos.config.nixpkgs.hostPlatform.system == system))
      (lib.mapAttrs' (name: nixos: lib.nameValuePair "configurations:nixos:${name}" nixos.config.system.build.toplevel))
    ];
  };
}
