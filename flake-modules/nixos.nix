# Provides an option for declaring NixOS configurations.
#
# Each entry under `configurations.nixos.<name>.module` becomes
# `nixosConfigurations.<name>` plus a `checks.<system>` entry pointing
# at the toplevel derivation, so `nix flake check` builds every host.
#
# Adapted from mightyiam/dendritic/example/modules/nixos.nix. The only
# addition over the upstream example: `specialArgs = { inherit inputs; }`
# so any module that needs raw flake inputs (e.g. the WSL fork imported
# from inputs.nixos-wsl) can read them from the module function's
# arguments. The dendritic migration is complete; this is now a
# permanent piece of substrate.
#
# Retire when: dendritic pattern itself is dropped. As long as
#   flake.modules.nixos.* is the publication channel, this dispatcher
#   is required.
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
          placeholder = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Mark this configuration as a placeholder (its
              hardware-configuration.nix is the all-zeros sentinel).
              The auto-generated `checks.<system>.configurations:nixos:<name>`
              entry is skipped so pure `nix flake check` still passes.
              Smoke-build with `nix build --impure
              .#nixosConfigurations.<name>.config.system.build.toplevel`
              and NIXOS_ALLOW_PLACEHOLDER=1.
            '';
          };
        };
      }
    );
    default = { };
  };

  config.flake = {
    nixosConfigurations = lib.flip lib.mapAttrs config.configurations.nixos (
      _name: { module, specialArgs, ... }: lib.nixosSystem {
        specialArgs = { inherit inputs; } // specialArgs;
        modules = [ module ];
      }
    );
  };

  config.perSystem = { system, ... }: {
    checks = lib.pipe config.configurations.nixos [
      (lib.filterAttrs (_name: cfg: !cfg.placeholder))
      (lib.mapAttrs (name: _cfg: config.flake.nixosConfigurations.${name}))
      (lib.filterAttrs (_name: nixos: nixos.config.nixpkgs.hostPlatform.system == system))
      (lib.mapAttrs' (name: nixos: lib.nameValuePair "configurations:nixos:${name}" nixos.config.system.build.toplevel))
    ];
  };
}
