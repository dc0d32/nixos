# Home-manager bundle: kid.
#
# Restricted desktop session for the pb-t480 kid accounts (m, s).
# Built as `dev ++ [kid-desktop-specific]`: the kids get the full
# TERMINAL dev/AI toolset (base + ai-cli + build-deps → gh, git, tmux,
# direnv, nix-settings, opencode/copilot, gcc/python/node, …) but a
# RESTRICTED desktop/GUI surface — `chrome` + `chrome-managed`
# (Family-Link-policy-locked Google Chrome, see
# flake-modules/chrome-managed.nix), `zoom` for school, and explicitly
# NOT the adult desktop's credential/GUI-admin tooling (no bitwarden,
# no polkit-agent).
#
# Policy note (2026-06-23): kids previously had no dev tooling at all.
# That was relaxed — m and s now do development + AI-assisted coding
# from their own accounts, so the bundle composes `dev` rather than a
# hand-picked CLI subset. The desktop restrictions (managed Chrome,
# no password manager, kid-launcher, timekpr screen-time on the host)
# are unchanged: kids are still kids on the GUI side.
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
# Members = dev ++ the kid desktop set:
#   dev (= base ++ ai-cli ++ build-deps):
#     btop direnv fish gh git nix-settings tmux vim zsh
#     + ai-cli (github-copilot-cli, opencode)
#     + build-deps (gcc/make/cmake, python3, nodejs, tree-sitter,
#       archive/transfer CLIs, …)
#   kid desktop-specific:
#   - alacritty                            terminal emulator
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
#   - hardware-hacking                     serial/USB/flashing CLIs
#                                          (esptool, picocom, dfu-util,
#                                          flashrom, usbutils, screen).
#                                          Functional on pb-t480 because
#                                          that host's NixOS module sets
#                                          hardware-hacking.extraUsers
#                                          to grant kids the device
#                                          groups.
#   - idle, niri, desktop-shell,           compositor stack +
#     lockscreen, wallpaper                 bar/launcher/notifications/
#                                            cliphist + swaylock-effects
#   - kid-launcher                         hides app-menu noise from
#                                          transitive deps
#                                          (qt6ct/easyeffects/satty/
#                                          thunar-settings/etc.) so the
#                                          launcher only shows things
#                                          kids actually use
#   - zoom                                 school meetings
#
# NOT in this bundle (per-host opt-in, to keep the kid-bundle
# closure lean):
#
#   - freecad   ~1.3 GiB DL — hosts that want CAD for kids append
#                `config.flake.modules.homeManager.freecad` to the
#                kid HM module (see flake-modules/hosts/m-pc.nix,
#                pb-t480.nix).
#
# Retire when: the kids age out and their accounts get merged with
#   the adult desktop bundle, OR the pb-t480 host is
#   decommissioned, OR Linux grows per-user policy enforcement so
#   chrome-managed can disappear.
{ config, ... }:
{
  flake.lib.bundles.homeManager.kid =
    config.flake.lib.bundles.homeManager.dev
    ++ (with config.flake.modules.homeManager; [
      alacritty
      audio
      bluetooth
      chrome
      chrome-managed
      desktop-extras
      desktop-shell
      electronics
      file-manager
      displays
      fonts
      hardware-hacking
      idle
      kid-launcher
      lockscreen
      niri
      vscode
      wallpaper
      zoom
    ]);
}
