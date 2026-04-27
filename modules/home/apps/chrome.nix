{ pkgs, lib, variables, ... }:
# Google Chrome — unfree, linux only. On macOS, install Chrome from the
# official download or Homebrew cask; nixpkgs doesn't package it for darwin.
let
  cfg = variables.apps.chrome or { enable = false; };
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
in
lib.mkIf ((cfg.enable or false) && isLinux) {
  home.packages = [ pkgs.google-chrome ];

  # Sensible chromium/chrome flags that apply cleanly on Wayland.
  home.sessionVariables = {
    # Let chrome use Wayland when available, X11 otherwise.
    NIXOS_OZONE_WL = "1";
  };

  # Disable WaylandWindowDecorations: the nixpkgs wrapper enables it when
  # NIXOS_OZONE_WL=1, but it causes Chrome to split its window into a
  # titlebar subsurface + content subsurface.  Under niri with prefer-no-csd
  # the input region on the content subsurface ends up misaligned, causing
  # intermittent missed clicks.  Disabling the feature collapses Chrome back
  # to a single surface with a correct input region.
  # Retire when the upstream Chromium Wayland subsurface input-region bug is
  # fixed and the nixpkgs wrapper stops injecting WaylandWindowDecorations.
  xdg.configFile."chrome-flags.conf".text = ''
    --disable-features=WaylandWindowDecorations
  '';
}
