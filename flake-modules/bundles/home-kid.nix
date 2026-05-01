# Home-manager bundle: kid.
#
# Restricted desktop session for the pb-t480 kid accounts (m, s).
# NOT a subset of the adult `desktop` bundle: kids get
# `chromium-managed` (Family-Link-policy-locked) instead of `chrome`,
# `zoom` for school meetings, and no dev/admin tooling
# (no ai-cli/build-deps/bitwarden/vscode/freecad/hardware-hacking,
# no chrome).
#
# Members (parallel to base+desktop, intentionally):
#   - alacritty, btop, neovim, zsh         minimal CLI surface
#   - chromium-managed                     policy-restricted browser
#   - desktop-extras, fonts                desktop niceties
#   - idle, niri, polkit-agent, quickshell, wallpaper   compositor stack
#   - zoom                                 school meetings
#
# Retire when: the kids age out and their accounts get merged with
#   the adult desktop bundle, OR the pb-t480 host is
#   decommissioned, OR Linux grows per-user policy enforcement so
#   chromium-managed can disappear.
{ config, ... }:
{
  flake.lib.bundles.homeManager.kid = with config.flake.modules.homeManager; [
    alacritty
    btop
    chromium-managed
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
