{ config, lib, pkgs, variables, ... }:
let
  cfg = variables.desktop.niri or { enable = false; };
in
lib.mkIf (cfg.enable or false) {
  home.pointerCursor = {
    package = pkgs.vanilla-dmz;
    gtk = {
      enable = true;
    };
    name = "DMZ-Black";
    size = 24;
  };

  home.sessionVariables = {
    XCURSOR_THEME = "DMZ-Black";
    XCURSOR_SIZE = 24;
  };

  xdg.configFile = {
    "gtk-4.0/settings.ini".text = ''
      [Settings]
      gtk-cursor-theme-name = DMZ-Black
      gtk-cursor-theme-size = 24
    '';
    "gtk-3.0/settings.ini".text = ''
      [Settings]
      gtk-cursor-theme-name = DMZ-Black
      gtk-cursor-theme-size = 24
    '';
  };
}
