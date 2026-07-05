# samba.nix — declarative SMB shares for the homelab storage node.
#
# Why this exists:
#   TrueNAS serves a few SMB shares today (mm, home, nas). After the
#   migration the storage node serves them natively. Hosts declare
#   `homelab.smb.shares.<name> = { path = …; }` and this wires
#   services.samba + opens the firewall.
#
# Inert until `homelab.smb.shares` is non-empty.
#
# Retire when: the homelab drops SMB (NFS-only), or services.samba's
# settings schema changes again.
{ ... }:
{
  flake.modules.nixos.samba = { config, lib, ... }:
    let
      cfg = config.homelab.smb;
      yesno = b: if b then "yes" else "no";
    in
    {
      options.homelab.smb.shares = lib.mkOption {
        default = { };
        description = "SMB shares keyed by share name.";
        example = {
          mm = { path = "/mnt/zrust/mm"; };
        };
        type = lib.types.attrsOf (lib.types.submodule (_: {
          options = {
            path = lib.mkOption { type = lib.types.str; };
            readOnly = lib.mkOption { type = lib.types.bool; default = false; };
            browseable = lib.mkOption { type = lib.types.bool; default = true; };
            guestOk = lib.mkOption { type = lib.types.bool; default = false; };
            validUsers = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
          };
        }));
      };

      config = lib.mkIf (cfg.shares != { }) {
        services.samba = {
          enable = true;
          openFirewall = true;
          settings = lib.mapAttrs
            (_name: s: {
              "path" = s.path;
              "read only" = yesno s.readOnly;
              "browseable" = yesno s.browseable;
              "guest ok" = yesno s.guestOk;
            } // lib.optionalAttrs (s.validUsers != [ ]) {
              "valid users" = lib.concatStringsSep " " s.validUsers;
            })
            cfg.shares;
        };
      };
    };
}
