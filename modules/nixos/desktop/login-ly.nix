{ config, lib, pkgs, variables, ... }:
# ly — a tiny TUI login manager. Lightweight, no Qt/GTK, looks great on a
# fresh terminal, works fine for launching niri (Wayland session).
#
# Enable with:
#   variables.login.ly.enable = true;
let cfg = variables.login.ly or { enable = false; };
in
lib.mkIf (cfg.enable or false) {
  # Use only one DM; default the others off so any future host enabling
  # gdm/sddm/lightdm only has to flip its own switch (mkDefault loses to
  # any explicit assignment in the host config).
  # Note: gdm/sddm live under services.displayManager.* in current nixpkgs,
  # but lightdm is still at services.xserver.displayManager.lightdm.
  services.displayManager.gdm.enable          = lib.mkDefault false;
  services.displayManager.sddm.enable         = lib.mkDefault false;
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

  # Niri provides a wayland session file via its module; ly will list it.
  # If other sessions are added later, they'll appear automatically too.
}
