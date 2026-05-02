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
# (esptool, picocom, dfu-util, flashrom) so they can flash RP2040 /
# ESP boards from their own accounts. The hardware-hacking NixOS
# module IS imported on pb-t480 with `extraUsers = [ "m" "s" ]` so
# the kids end up in dialout/plugdev/uucp and can actually talk to
# the devices without sudo. KiCad is intentionally NOT in the kid
# bundle — see flake-modules/kicad.nix; kids haven't asked for EDA
# yet and a ~1 GB closure isn't worth carrying speculatively.
#
# polkit-agent is intentionally NOT included. Kids are not in
# `wheel` and have no business authenticating polkit prompts;
# udisks2's default rule already permits active-session removable-
# media mounts without a password (so USB sticks via Thunar still
# work), and the rare polkit-gated action (blueman adapter
# settings, NetworkManager system settings) is supposed to fail —
# they should ask p.
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
#   - file-manager                         Thunar + gvfs + thunar-volman;
#                                          mounts USB drives, browses
#                                          MTP phones, extracts zips.
#                                          Pairs with the NixOS half
#                                          on pb-t480 (gvfs + udisks2).
#   - freecad                              CAD with FusionLike preset
#                                          pack + addons (Assembly4,
#                                          Fasteners, SheetMetal,
#                                          Defeaturing)
#   - hardware-hacking                     serial/USB/flashing CLIs
#                                          (esptool, picocom, dfu-util,
#                                          flashrom, usbutils, screen).
#                                          Functional on pb-t480 because
#                                          that host's NixOS module sets
#                                          hardware-hacking.extraUsers
#                                          to grant kids the device
#                                          groups.
#   - idle, niri, quickshell, wallpaper    compositor stack
#   - kid-launcher                         hides app-menu noise from
#                                          transitive deps
#                                          (qt6ct/easyeffects/satty/
#                                          thunar-settings/etc.) so the
#                                          launcher only shows things
#                                          kids actually use
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
    file-manager
    fonts
    freecad
    hardware-hacking
    idle
    kid-launcher
    niri
    quickshell
    wallpaper
    zoom
    zsh
  ];
}
