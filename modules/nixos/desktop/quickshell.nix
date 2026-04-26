{ config, lib, pkgs, variables, ... }:
let
  cfg = variables.desktop.quickshell or { enable = false; };
  enabled = cfg.enable or false;
in
{
  config = lib.mkIf enabled {
    services.displayManager = {
      lightdm.enable = true;
      settings = {
        greeter = {
          session-wrapper = "greeter";
        };
      };
    };

    environment.systemPackages = with pkgs; [
      wl-clipboard
      wlr-randr
      brightnessctl
      playerctl
      grim
      slurp
      swaylock
      swayidle
    ];

    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    };

    services.dbus.enable = true;
    security.polkit.enable = true;
  };
}