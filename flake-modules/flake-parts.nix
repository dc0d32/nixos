# Enables the `flake.modules.<class>.<name>` machinery used by every
# feature module to contribute config to NixOS / home-manager / etc.
# https://flake.parts/options/flake-parts-modules.html
#
# Safe to delete only if/when the dendritic pattern itself is abandoned.
{ inputs, ... }:
{
  imports = [
    inputs.flake-parts.flakeModules.modules
  ];
}
