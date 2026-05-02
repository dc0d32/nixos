# Home-manager bundle: kid.
#
# Restricted desktop session for the pb-t480 kid accounts (m, s).
# NOT a subset of the adult `desktop` bundle: kids get
# `chrome` + `chrome-managed` (Family-Link-policy-locked Google
# Chrome — see flake-modules/chrome-managed.nix for why we use
# Chrome instead of Chromium), `zoom` for school meetings, and no
# dev/admin tooling (no ai-cli/build-deps/bitwarden/vscode/freecad/
# hardware-hacking).
#
# Members (parallel to base+desktop, intentionally):
#   - alacritty, btop, neovim, zsh         minimal CLI surface
#   - bluetooth                            blueman applet for tray pairing
#   - chrome                               browser binary (google-chrome)
#   - chrome-managed                       no-op HM stub; the matching
#                                          NixOS module drops the
#                                          managed-policy JSON
#   - desktop-extras, fonts                desktop niceties
#   - idle, niri, polkit-agent, quickshell, wallpaper   compositor stack
#   - zoom                                 school meetings
#
# Retire when: the kids age out and their accounts get merged with
#   the adult desktop bundle, OR the pb-t480 host is
#   decommissioned, OR Linux grows per-user policy enforcement so
#   chrome-managed can disappear.
{ config, ... }:
{
  flake.lib.bundles.homeManager.kid = with config.flake.modules.homeManager; [
    alacritty
    bluetooth
    btop
    chrome
    chrome-managed
    desktop-extras
    fonts
    idle
    neovim
    niri
    polkit-agent
    quickshell
    wallpaper
    zoom
    zsh
  ];
}
