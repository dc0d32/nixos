# syncoid.nix — ZFS replication (DR) for the homelab.
#
# Why this exists:
#   Restore tier 2: replicate critical datasets to the other node so a
#   node/pool loss is recoverable (the edge node's critical services →
#   the storage node).
#   Hosts declare `homelab.replication.<id> = { source = …; target = …; }`.
#
# Inert until `homelab.replication` is non-empty. SSH access to remote
# targets (keys) is host/runtime config, not here.
#
# Retire when: the homelab moves off ZFS send/recv for DR.
{ ... }:
{
  flake.modules.nixos.syncoid = { config, lib, ... }:
    let
      cfg = config.homelab.replication;
    in
    {
      options.homelab.replication = lib.mkOption {
        default = { };
        description = "syncoid replication jobs, keyed by id.";
        example = {
          "edge-critical" = {
            source = "rpool/apps";
            target = "root@storage-node:tank/backup/edge";
          };
        };
        type = lib.types.attrsOf (lib.types.submodule (_: {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              description = "Source dataset.";
            };
            target = lib.mkOption {
              type = lib.types.str;
              description = "Target as [user@host:]dataset.";
            };
            recursive = lib.mkOption { type = lib.types.bool; default = true; };
          };
        }));
      };

      config = lib.mkIf (cfg != { }) {
        services.syncoid = {
          enable = true;
          commands = lib.mapAttrs
            (_id: j: {
              inherit (j) source target recursive;
              extraArgs = [ "--no-sync-snap" ];
            })
            cfg;
        };
      };
    };
}
