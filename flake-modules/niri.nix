# niri — scrollable-tiling Wayland compositor (NixOS side).
#
# This is the system-side installation: enables programs.niri,
# pulls in companion CLI tools, wires xdg-portal to the gtk + wlr
# backends, brings up dbus + polkit + power-profiles-daemon +
# upower, and disables the niri-flake polkit agent so our own
# hyprpolkitagent (HM-side) doesn't race with it.
#
# The user-side niri config (the kdl file, keybinds, layout) lives
# in flake-modules/desktop-niri.nix on the homeManager class once
# that migrates.
#
# Pattern A: hosts opt in by importing this module. Headless / WSL
# hosts simply don't import it, so inputs.niri's nixosModule is
# never imported either — desktops that don't run niri don't pay
# the eval cost.
#
# Migrated from modules/nixos/desktop/niri.nix.
{ ... }:
{
  flake.modules.nixos.niri = { inputs, lib, pkgs, ... }: {
    imports = [ inputs.niri.nixosModules.niri ];

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
    ];

    xdg.portal = {
      enable = true;
      extraPortals = with pkgs; [
        xdg-desktop-portal-gtk
        xdg-desktop-portal-wlr # screenshare/screencast for wlroots compositors
      ];
      # Without an explicit config, xdg-desktop-portal matches
      # backends by UseIn= in *.portal files. Both gtk.portal and
      # gnome.portal declare UseIn=gnome, which is wrong for niri
      # and causes gnome-portal to be activated alongside (or
      # instead of) gtk-portal, leading to startup races and timeout
      # failures. Pin niri to the gtk backend explicitly, using wlr
      # for screencast.
      config.niri = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
      };
    };

    services.dbus.enable = true;
    security.polkit.enable = true;
    services.power-profiles-daemon.enable = lib.mkDefault true;

    # UPower daemon — provides org.freedesktop.UPower over system
    # dbus, which quickshell's Quickshell.Services.UPower
    # (BatteryState.qml) consumes for battery percentage / charging
    # state. Without this, only the power-profiles-daemon-provided
    # org.freedesktop.UPower.PowerProfiles interface is on the bus,
    # and BatteryState.present stays false → the battery chip is
    # hidden. Safe to leave on for desktops without a battery
    # (UPower simply reports no laptop battery and BatteryState
    # hides itself).
    services.upower.enable = lib.mkDefault true;

    # niri-flake auto-installs polkit-kde-authentication-agent-1 as
    # a user systemd unit (niri-flake-polkit.service,
    # WantedBy=niri.service). We already run hyprpolkitagent
    # ourselves (see modules/home/desktop/polkit-agent.nix); two
    # agents racing on the same dbus subject yields
    #   "Cannot register authentication agent: ... agent already
    #    exists for the given subject"
    # and the loser flaps until systemd's restart counter trips,
    # leaving the user session degraded. Disable the niri-flake
    # one. Documented opt-out per niri-flake README.
    systemd.user.services.niri-flake-polkit.enable = false;
  };
}
