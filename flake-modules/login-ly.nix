# ly — a tiny TUI login manager. Lightweight, no Qt/GTK, looks great
# on a fresh terminal, works fine for launching niri (Wayland session).
#
# Pattern A: hosts opt in by importing this module. Headless / WSL
# hosts simply don't import it.
#
# Niri (or any other Wayland/X session module) provides its own
# wayland-sessions/.desktop entry; ly will list whatever's available
# automatically.
#
# Migrated from modules/nixos/desktop/login-ly.nix.
{ ... }:
{
  flake.modules.nixos.login-ly = { lib, ... }: {
    # Use only one DM; default the others off so any future host
    # enabling gdm/sddm/lightdm only has to flip its own switch
    # (mkDefault loses to any explicit assignment in the host
    # config).
    # Note: gdm/sddm live under services.displayManager.* in current
    # nixpkgs, but lightdm is still at
    # services.xserver.displayManager.lightdm.
    services.displayManager.gdm.enable = lib.mkDefault false;
    services.displayManager.sddm.enable = lib.mkDefault false;
    services.xserver.displayManager.lightdm.enable = lib.mkDefault false;

    services.displayManager.ly = {
      enable = true;
      settings = {
        animation = "matrix";
        clock = "%F  %T";
        clear_password = true;
        hide_borders = false;
        blank_box = true;
        bigclock = false;
      };
    };
  };
}
