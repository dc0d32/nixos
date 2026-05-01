# steam.nix — Steam game launcher / storefront (NixOS).
#
# Why this module exists:
#   Steam is system-wide on NixOS (programs.steam.enable wires up the
#   FHS runtime, udev rules for controllers, the steam-run wrapper, and
#   pulls in 32-bit graphics libs). It is NOT a plain home.packages
#   install — using pkgs.steam directly skips the runtime setup and
#   most games refuse to launch. Packaging it as its own dendritic
#   module lets hosts opt in via import.
#
# Why no remote-play / dedicated-server / gamescope sub-options:
#   - remotePlay.openFirewall opens UDP 27031-27036 for streaming TO
#     this host from another machine on the LAN. Family-laptop is the
#     CONSUMER of games (kids playing locally), not a Steam Link host
#     for another machine; opening ports is unnecessary attack surface.
#   - dedicatedServer is for hosting headless game servers.
#   - gamescopeSession adds a SteamOS-style session option to the
#     display manager — irrelevant under niri.
#   Re-enable any of these here if a host actually needs them; the
#   defaults stay laptop-conservative.
#
# Parental controls reminder:
#   This module does NOT enforce game/store/chat restrictions. Those
#   are configured per-Steam-account inside Steam (Settings → Family →
#   Family View, PIN-protected). Set those up once per kid Steam
#   account after first launch. OS-side enforcement is not feasible —
#   Steam content lives in the Steam binary and depots, not the
#   filesystem we control.
#
# Retire when:
#   - Every consumer drops Steam (unlikely), OR
#   - Steam ships an official Flatpak that supersedes the NixOS
#     programs.steam wiring.
{
  flake.modules.nixos.steam = {
    programs.steam.enable = true;
  };
}
