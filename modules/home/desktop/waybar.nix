{ lib, variables, ... }:
let cfg = variables.desktop.waybar or { enable = false; };
in
lib.mkIf (cfg.enable or false) {
  programs.waybar = {
    enable = true;
    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 28;
      modules-left = [ "niri/workspaces" ];
      modules-center = [ "clock" ];
      modules-right = [ "pulseaudio" "network" "battery" "tray" ];
      clock.format = "{:%a %Y-%m-%d  %H:%M}";
    };
  };
}
