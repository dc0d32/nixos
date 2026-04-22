{ config, lib, pkgs, inputs, variables, ... }:
# NixOS running inside WSL2 (including Windows on ARM via aarch64-linux).
#
# Uses github:dc0d32/nixos-aarch64-wsl, which publishes both x86_64-linux
# and aarch64-linux WSL rootfs tarballs. That flake exposes a file
# `wsl.nix` at its repo root (not a nixosModules output) and expects
# a `defaultUser` specialArg. We import the file directly and inject
# defaultUser via _module.args.
let
  cfg = variables.wsl or { enable = false; };
  wslUser = cfg.defaultUser or variables.user or "nixos";
in
lib.mkIf (cfg.enable or false) {
  imports = [ (inputs.nixos-wsl + "/wsl.nix") ];

  # The fork's wsl.nix reads `defaultUser` from module args.
  _module.args.defaultUser = wslUser;

  # --- Force-disable things our other modules might turn on ---
  # (The fork's wsl.nix already handles boot/networking/firewall/power;
  # these stay as belt-and-suspenders for modules we layer on top.)

  programs.niri.enable = lib.mkForce false;
  services.displayManager.ly.enable = lib.mkForce false;

  services.pipewire.enable = lib.mkForce false;
  services.pulseaudio.enable = lib.mkForce false;

  networking.networkmanager.enable = lib.mkForce false;

  services.thermald.enable = lib.mkForce false;
  services.fwupd.enable = lib.mkForce false;

  hardware.graphics.enable = lib.mkForce false;
  services.xserver.videoDrivers = lib.mkForce [ ];

  # Make the wsl user's shell zsh so defaults line up with the rest of the flake.
  users.users.${wslUser}.shell = lib.mkForce pkgs.zsh;
}
