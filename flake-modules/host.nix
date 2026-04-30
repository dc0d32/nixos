# Host metadata — top-level options describing the machine's identity
# (hostname, primary user, system architecture). Set per-host by each
# host module under ./hosts/. Read by feature modules that need to
# reference the user (e.g. for users.users.<user>.extraGroups) or the
# hostname (for networking.hostName).
#
# Modeled on mightyiam/dendritic/example/modules/meta.nix's
# `username` option, but namespaced under `host.*` because we have
# more than one such field and the namespace doubles as documentation.
{ lib, ... }:
{
  options.host = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Short hostname (becomes networking.hostName).";
    };
    user = lib.mkOption {
      type = lib.types.str;
      description = "Primary user account on this host.";
    };
    system = lib.mkOption {
      type = lib.types.enum [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      description = "Nix system tuple this host builds for.";
    };
    stateVersion = lib.mkOption {
      type = lib.types.str;
      description = "NixOS / home-manager state version pin.";
    };
  };
}
