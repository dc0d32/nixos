# nfs-client.nix — declarative NFS client mounts for homelab hosts.
#
# Why this exists:
#   The homelab hosts consume shared datasets from the storage node
#   (TrueNAS today, andromeda after the migration) over NFS. Rather than
#   hand-writing `fileSystems.*` blocks per host, hosts declare
#   `homelab.nfs.mounts.<mountpoint> = { device = "<server>:/<path>"; }`
#   and this module synthesizes the `fileSystems` entries. Mounts are
#   `_netdev` + `x-systemd.automount` so a slow or absent server never
#   blocks boot — important while the storage node and clients are being
#   migrated one at a time.
#
# Retire when:
#   * The homelab moves to a different shared-storage transport (e.g. a
#     distributed FS), OR
#   * NixOS gains an equivalent first-class declarative NFS-client helper.
{ ... }:
{
  flake.modules.nixos.nfs-client = { config, lib, ... }:
    let
      cfg = config.homelab.nfs;
    in
    {
      options.homelab.nfs.mounts = lib.mkOption {
        default = { };
        description = ''
          NFS mounts keyed by mountpoint. Each becomes one
          `fileSystems.<mountpoint>` entry, automounted and `_netdev`.
        '';
        example = {
          "/mnt/mm".device = "192.168.10.3:/mnt/zrust/mm";
        };
        type = lib.types.attrsOf (lib.types.submodule (_: {
          options = {
            device = lib.mkOption {
              type = lib.types.str;
              example = "192.168.10.3:/mnt/zrust/mm";
              description = "NFS export as <server>:/<path>.";
            };
            fsType = lib.mkOption {
              type = lib.types.str;
              default = "nfs4";
              description = "Filesystem type passed to mount.";
            };
            mountOptions = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [
                "noatime"
                "x-systemd.automount"
                "x-systemd.idle-timeout=600"
                "_netdev"
              ];
              description = "mount(8) options.";
            };
          };
        }));
      };

      config = lib.mkIf (cfg.mounts != { }) {
        boot.supportedFilesystems = [ "nfs" ];
        fileSystems = lib.mapAttrs
          (_mountpoint: m: {
            inherit (m) device fsType;
            options = m.mountOptions;
          })
          cfg.mounts;
      };
    };
}
