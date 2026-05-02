# Home-manager bundle: kid.
#
# Restricted desktop session for the pb-t480 kid accounts (m, s).
# NOT a subset of the adult `desktop` bundle: kids get
# `chrome` + `chrome-managed` (Family-Link-policy-locked Google
# Chrome — see flake-modules/chrome-managed.nix for why we use
# Chrome instead of Chromium), `zoom` for school meetings, and no
# admin / network-secrets tooling (no ai-cli/build-deps/bitwarden/
# vscode).
#
# Kids DO get freecad and the user-side hardware-hacking tools
# (KiCad, esptool, picocom, etc.) so they can do CAD/EDA on their
# own accounts. The hardware-hacking NixOS module is intentionally
# NOT imported on pb-t480 — kids are not in dialout/plugdev/uucp,
# so they can run lsusb and design boards but cannot flash hardware
# without an adult logging in. See flake-modules/hosts/pb-t480.nix
# for the host-level wiring decision.
#
# Members (parallel to base+desktop, intentionally):
#   - alacritty, btop, vim, zsh            minimal CLI surface
#   - audio                                easyeffects daemon (passthrough
#                                          unless host sets presets/IRS;
#                                          ensures kids get the same
#                                          PipeWire stack handling as p)
#   - bluetooth                            blueman applet for tray pairing
#   - chrome                               browser binary (google-chrome)
#   - chrome-managed                       no-op HM stub; the matching
#                                          NixOS module drops the
#                                          managed-policy JSON
#   - desktop-extras, fonts                desktop niceties
#   - freecad                              CAD with FusionLike preset
#                                          pack + addons (Assembly4,
#                                          Fasteners, SheetMetal,
#                                          Defeaturing)
#   - hardware-hacking                     KiCad + serial/USB/flashing
#                                          CLIs. Useful tools to flash
#                                          devices won't actually work
#                                          on a kid account because the
#                                          NixOS half of the module
#                                          (udev + dialout/plugdev) is
#                                          gated on `users.primary` and
#                                          pb-t480 sets that to `p`.
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
    audio
    bluetooth
    btop
    chrome
    chrome-managed
    desktop-extras
    fonts
    freecad
    hardware-hacking
    idle
    niri
    polkit-agent
    quickshell
    wallpaper
    zoom
    zsh
  ];
}
