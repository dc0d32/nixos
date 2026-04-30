{ lib, variables ? { }, ... }:
# This file is the last vestige of the legacy modules/home/ aggregator.
# All feature modules have migrated to flake-modules/. Once the final
# cleanup commit moves `programs.home-manager.enable = true` into a
# dedicated dendritic module (or into the host bridge), this file can
# go away entirely.
{
  programs.home-manager.enable = true;
}
