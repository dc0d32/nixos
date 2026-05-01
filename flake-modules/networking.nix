# Networking — NetworkManager + firewall.
#
# Pattern A: hosts opt in by importing this module. WSL hosts don't
# import it (the WSL fork manages networking from the Windows side).
# mkDefault on both settings so a host that *does* import this can
# still override either knob without ceremony.
#
# Retire when: NetworkManager is replaced by a different stack (e.g.
#   systemd-networkd + iwd) across every host that imports it, OR
#   NixOS upstream provides equivalent defaults that make this thin
#   wrapper redundant.
{ ... }:
{
  flake.modules.nixos.networking = { lib, ... }: {
    networking.networkmanager.enable = lib.mkDefault true;
    networking.firewall.enable = lib.mkDefault true;
  };
}
