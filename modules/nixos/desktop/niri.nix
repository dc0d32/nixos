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
      mako
      fuzzel
      xdg-utils
      stasis
    ];

    xdg.portal = {
      enable = true;
      extraPortals = with pkgs; [
        xdg-desktop-portal-gtk
        xdg-desktop-portal-wlr   # screenshare/screencast for wlroots compositors
      ];
      # Without an explicit config, xdg-desktop-portal matches backends by
      # UseIn= in *.portal files.  Both gtk.portal and gnome.portal declare
      # UseIn=gnome, which is wrong for niri and causes gnome-portal to be
      # activated alongside (or instead of) gtk-portal, leading to startup
      # races and timeout failures.  Pin niri to the gtk backend explicitly,
      # using wlr for screencast.
      config.niri = {
        default     = [ "gtk" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
      };
    };

    services.dbus.enable = true;
    security.polkit.enable = true;
  };
}
