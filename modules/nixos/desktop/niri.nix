{ config, lib, pkgs, inputs, variables, ... }:
let cfg = variables.desktop.niri or { enable = false; };
in
lib.mkIf (cfg.enable or false) {
  # niri-flake provides a NixOS module via inputs.niri.nixosModules.niri
  imports = lib.optional (inputs ? niri) inputs.niri.nixosModules.niri;

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
}
