# Declare merge-friendly options for `flake.lib` and the bundles
# namespace.
#
# By default flake-parts marks every `flake.<X>` (and every leaf below
# it) as `types.unique`, meaning only one module can define each path.
# We need multiple contributors:
#   - `flake-modules/mk-pkgs.nix` defines `flake.lib.mkPkgs`
#   - each `flake-modules/bundles/<x>.nix` defines
#     `flake.lib.bundles.homeManager.<x>`
# without fighting each other. Re-declare with attrset types deep
# enough to cover both.
#
# Retire when: flake-parts ships its own merge-friendly flake.lib
#   declaration (see https://github.com/hercules-ci/flake-parts
#   issue 76 and successors), at which point this stub becomes
#   redundant.
{ lib, ... }:
{
  options.flake.lib = lib.mkOption {
    type = lib.types.submodule {
      freeformType = lib.types.lazyAttrsOf lib.types.raw;
      options.bundles = lib.mkOption {
        type = lib.types.submodule {
          options.homeManager = lib.mkOption {
            type = lib.types.lazyAttrsOf (lib.types.listOf lib.types.raw);
            default = { };
            description = ''
              Named lists of home-manager modules. Each entry is a
              ready-to-splice import list for an HM configuration.
            '';
          };
        };
        default = { };
      };
    };
    default = { };
    description = ''
      Flake-wide helpers. Contributed to by multiple modules; merged
      at the leaf attribute level.
    '';
  };
}
