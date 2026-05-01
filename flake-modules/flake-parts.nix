# Enables the `flake.modules.<class>.<name>` machinery used by every
# feature module to contribute config to NixOS / home-manager / etc.
# https://flake.parts/options/flake-parts-modules.html
#
# Safe to delete only if/when the dendritic pattern itself is abandoned.
#
# Retire when: never. flake-parts is the core abstraction this entire
#   tree is built on; removing it means rewriting the flake from scratch.
{ inputs, ... }:
{
  imports = [
    inputs.flake-parts.flakeModules.modules
  ];
}
