{ config, lib, pkgs, inputs, variables, ... }:
# `imports` is resolved before config evaluation, so it cannot live inside
# lib.mkIf. Split: top-level imports gated via lib.optional on enable +
# flake presence, and the config block under lib.mkIf.
let
  cfg = variables.desktop.niri or { enable = false; };
  enabled = cfg.enable or false;
in
{
  imports = lib.optional (enabled && (inputs ? niri)) inputs.niri.nixosModules.niri;

  config = lib.mkIf enabled {
    programs.niri.enable = true;

    # Useful companions
    environment.systemPackages = with pkgs; [
      wl-clipboard
      wlr-randr
      brightnessctl
      playerctl
      grim
      slurp
      swaybg
      swaylock
      swayidle
      mako
      fuzzel
      xdg-utils
    ];

    xdg.portal = {
      enable = true;
      extraPortals = with pkgs; [ xdg-desktop-portal-gtk ];
    };

    services.dbus.enable = true;
    security.polkit.enable = true;
  };
}
