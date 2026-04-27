{ config, lib, pkgs, variables, ... }:
let
  cfg = variables.idle or { enable = true; };
in
lib.mkIf (cfg.enable) {
  home.packages = with pkgs; [ brightnessctl stasis ];

  xdg.configFile."stasis" = {
    source = ./stasis;
    recursive = true;
    force = true;
  };

  programs.niri.settings.spawn-at-startup = lib.mkAfter [
    { command = [ "stasis" ]; }
  ];
}