# sanoid.nix — declarative ZFS snapshot policies (sanoid) for homelab.
#
# Why this exists:
#   Per-dataset snapshot retention is the first restore tier (see the
#   design doc's "Restore & backup tiers"). Hosts declare
#   `homelab.snapshots.<dataset> = { daily = …; … }` and this wires
#   services.sanoid. Pairs with syncoid (replication) and offsite-restic.
#
# Inert until `homelab.snapshots` is non-empty.
#
# Retire when: the homelab moves off ZFS snapshots for local retention.
{ ... }:
{
  flake.modules.nixos.sanoid = { config, lib, ... }:
    let
      cfg = config.homelab.snapshots;
    in
    {
      options.homelab.snapshots = lib.mkOption {
        default = { };
        description = "sanoid snapshot policy, keyed by ZFS dataset.";
        example = {
          "zrust/vault".recursive = true;
        };
        type = lib.types.attrsOf (lib.types.submodule (_: {
          options = {
            recursive = lib.mkOption { type = lib.types.bool; default = false; };
            hourly = lib.mkOption { type = lib.types.ints.unsigned; default = 24; };
            daily = lib.mkOption { type = lib.types.ints.unsigned; default = 14; };
            weekly = lib.mkOption { type = lib.types.ints.unsigned; default = 4; };
            monthly = lib.mkOption { type = lib.types.ints.unsigned; default = 3; };
            autosnap = lib.mkOption { type = lib.types.bool; default = true; };
            autoprune = lib.mkOption { type = lib.types.bool; default = true; };
          };
        }));
      };

      config = lib.mkIf (cfg != { }) {
        services.sanoid = {
          enable = true;
          datasets = lib.mapAttrs
            (_ds: p: {
              inherit (p) recursive hourly daily weekly monthly autosnap autoprune;
            })
            cfg;
        };
      };
    };
}
