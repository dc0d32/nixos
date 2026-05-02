# Home-manager bundle: desktop.
#
# Full desktop session for an adult/admin user: dev bundle plus
# compositor (niri), bar/lockscreen (quickshell), browsers (firefox
# as primary daily driver, chrome as fallback / for sites that
# need a chromium engine), password manager (bitwarden), editor
# with GUI (vscode), terminal (alacritty), audio DSP daemon
# (easyeffects via the audio module — preset/IRS deployment is
# host-controlled by setting `audio.presetsDir`/`irsDir`/`autoloads`
# on the host bridge), and friends. Currently consumed by my
# account on pb-x1 and pb-t480.
#
# = dev ++ [
#     alacritty audio bitwarden bluetooth chrome desktop-extras
#     file-manager firefox fonts freecad hardware-hacking idle
#     kicad niri polkit-agent quickshell vscode wallpaper
#   ]
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
      bitwarden
      bluetooth
      chrome
      desktop-extras
      file-manager
      firefox
      fonts
      freecad
      hardware-hacking
      idle
      kicad
      niri
      polkit-agent
      quickshell
      vscode
      wallpaper
    ]);
}
