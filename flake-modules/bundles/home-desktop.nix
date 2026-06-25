# Home-manager bundle: desktop.
#
# Full desktop session for an adult/admin user: dev bundle plus
# compositor (niri), shell (waybar/mako/fuzzel/cliphist via
# `desktop-shell`), lockscreen (swaylock-effects), browsers (firefox
# as primary daily driver, chrome as fallback / for sites that
# need a chromium engine), editor with GUI (vscode), terminal
# (alacritty), audio DSP daemon
# (easyeffects via the audio module — preset/IRS deployment is
# host-controlled by setting `audio.presetsDir`/`irsDir`/`autoloads`
# on the host bridge), and friends. Currently consumed by my
# account on pb-x1 and pb-t480.
#
# = dev ++ [
#     alacritty audio bluetooth chrome desktop-extras
#     desktop-shell file-manager fonts hardware-hacking idle
#     lockscreen niri polkit-agent vscode wallpaper
#   ]
#
# Modules intentionally NOT in this bundle (per-host opt-in, because
# each is a fat download that not every desktop host wants):
#
#   - kicad     ~865 MiB DL / 2.9 GiB on disk (EDA)
#   - freecad   ~1.3 GiB DL / 7.1 GiB on disk (CAD; biggest hitter)
#   - firefox   ~382 MiB DL / 1.5 GiB on disk
#
# Hosts that want any of these append
# `config.flake.modules.homeManager.<name>` to their HM imports
# explicitly (see flake-modules/hosts/pb-x1.nix etc.).
#
# Adding a new module that should appear on every adult desktop:
# add it here.
#
# Retire when: the flake stops having any desktop hosts (e.g. you
#   move entirely to a remote/headless model with X-forwarding or a
#   thin client), OR home-dev is retired.
{ config, ... }:
{
  flake.lib.bundles.homeManager.desktop =
    config.flake.lib.bundles.homeManager.dev
    ++ (with config.flake.modules.homeManager; [
      alacritty
      audio
      bluetooth
      chrome
      desktop-extras
      desktop-shell
      file-manager
      fonts
      idle
      lockscreen
      niri
      polkit-agent
      vscode
      wallpaper
    ]);
}
