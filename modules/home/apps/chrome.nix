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
}
