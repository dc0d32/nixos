# zfs-storage.nix — ZFS host baseline for homelab storage nodes.
#
# Why this exists:
#   The storage node (andromeda after the migration) imports the existing
#   `zrust` pool and needs the standard ZFS hygiene: import at boot, weekly
#   scrub, autotrim, and an ARC cap so containers + ZFS share RAM sanely.
#   ursa imports its local pools the same way. Encoding it once keeps both
#   nodes' storage config identical apart from the pool list.
#
#   The pool is NEVER created here — it is `zpool import`ed (the migration
#   re-homes the existing OpenZFS pool from TrueNAS untouched). disko owns
#   only the boot disk; the data pool disks are never named to disko (see
#   disko-safety.nix).
#
# Inert until `homelab.zfs.pools` is non-empty.
#
# Retire when:
#   * The homelab moves off ZFS (unlikely — ZFS is the point), OR
#   * NixOS restructures the ZFS options this wraps.
{ ... }:
{
  flake.modules.nixos.zfs-storage = { config, lib, ... }:
    let
      cfg = config.homelab.zfs;
    in
    {
      options.homelab.zfs = {
        pools = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "zrust" ];
          description = "Pools to import at boot (already-existing pools).";
        };
        arcMaxGiB = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          example = 16;
          description = "ZFS ARC max in GiB (null = ZFS default, ~half RAM).";
        };
      };

      config = lib.mkIf (cfg.pools != [ ]) {
        boot.supportedFilesystems = [ "zfs" ];
        # Import these existing pools at boot (not create).
        boot.zfs.extraPools = cfg.pools;

        services.zfs.autoScrub.enable = true;
        services.zfs.trim.enable = true;

        # ARC cap via modprobe (bytes). Only when explicitly set.
        boot.extraModprobeConfig = lib.mkIf (cfg.arcMaxGiB != null)
          "options zfs zfs_arc_max=${toString (cfg.arcMaxGiB * 1024 * 1024 * 1024)}";

        # ZFS refuses to import without a stable hostId; force the host to
        # declare one rather than silently generating an unstable default.
        assertions = [{
          assertion = (config.networking.hostId or "") != "";
          message = ''
            homelab.zfs: networking.hostId must be set (8 hex chars) on a
            host that imports ZFS pools ${toString cfg.pools}. Generate with
            `head -c4 /dev/urandom | od -A none -t x4`.
          '';
        }];
      };
    };
}
