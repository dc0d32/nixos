# nfs-server.nix — declarative NFS exports for the homelab storage node.
#
# Why this exists:
#   The storage node re-exports `zrust` datasets to the other node + the
#   apphosts (the same role TrueNAS plays today). Hosts declare
#   `homelab.nfs.exports."/mnt/zrust/mm".clients = [ … ]` and this wires
#   services.nfs.server + opens the firewall. Complements nfs-client.nix
#   (which declares `homelab.nfs.mounts`); both extend the `homelab.nfs`
#   namespace.
#
# Inert until `homelab.nfs.exports` is non-empty.
#
# Retire when: the homelab moves off NFS for shared storage.
{ ... }:
{
  flake.modules.nixos.nfs-server = { config, lib, ... }:
    let
      cfg = config.homelab.nfs;
      exportLine = path: e:
        let
          clients = lib.concatMapStringsSep " "
            (c: "${c.host}(${c.options})")
            e.clients;
        in
        "${path} ${clients}";
      exportsStr = lib.concatStringsSep "\n"
        (lib.mapAttrsToList exportLine cfg.exports);
    in
    {
      options.homelab.nfs.exports = lib.mkOption {
        default = { };
        description = "NFS exports keyed by exported path.";
        example = {
          "/mnt/zrust/mm".clients = [
            { host = "192.168.10.14"; options = "rw,sync,no_subtree_check"; }
          ];
        };
        type = lib.types.attrsOf (lib.types.submodule (_: {
          options.clients = lib.mkOption {
            default = [ ];
            type = lib.types.listOf (lib.types.submodule (_: {
              options = {
                host = lib.mkOption {
                  type = lib.types.str;
                  example = "192.168.10.14";
                  description = "Client host/IP/CIDR.";
                };
                options = lib.mkOption {
                  type = lib.types.str;
                  default = "rw,sync,no_subtree_check,root_squash";
                  description = "Per-client export(5) options.";
                };
              };
            }));
          };
        }));
      };

      config = lib.mkIf (cfg.exports != { }) {
        services.nfs.server = {
          enable = true;
          exports = exportsStr;
        };
        networking.firewall.allowedTCPPorts = [ 2049 ];
        networking.firewall.allowedUDPPorts = [ 2049 ];
      };
    };
}
