{ config, lib, pkgs, inputs, variables, ... }:
# NixOS running inside WSL2 (including Windows on ARM via aarch64-linux).
#
# Uses github:dc0d32/nixos-aarch64-wsl, which publishes both x86_64-linux
# and aarch64-linux WSL rootfs tarballs. That flake exposes a file
# `wsl.nix` at its repo root (not a nixosModules output) and expects
# a `defaultUser` specialArg. We import the file directly and inject
# defaultUser via _module.args.
#
# IMPORTANT: `imports` is resolved before config evaluation, so it cannot
# live inside `lib.mkIf`. Instead we conditionalise the import *list* using
# `lib.optionals`, and wrap the config body in `lib.mkIf`. On non-WSL hosts
# the inputs.nixos-wsl flake is never imported, so desktop machines don't
# evaluate it.
let
  cfg = variables.wsl or { enable = false; };
  wslEnabled = cfg.enable or false;
  wslUser = cfg.defaultUser or variables.user or "nixos";
in
{
  imports = lib.optionals wslEnabled [ (inputs.nixos-wsl + "/wsl.nix") ];

  config = lib.mkIf wslEnabled {
    # The fork's wsl.nix reads `defaultUser` from module args.
    _module.args.defaultUser = wslUser;

    # --- Force-disable things our other modules might turn on ---
    # Base modules now use lib.mkDefault for policy options, so plain values
    # from the upstream WSL fork already win without any intervention here.
    # These mkForce entries are kept as belt-and-suspenders: they guarantee
    # the value even if a host's variables.nix flips an `enable` flag that
    # would otherwise re-enable a layer (e.g. niri, pipewire) on WSL.

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
    # Force both the per-user shell AND the system default — the upstream WSL
    # fork sets users.defaultUserShell to bash at mkDefault priority, which
    # would otherwise collide with our users.nix (also mkDefault).
    users.users.${wslUser}.shell = lib.mkForce pkgs.zsh;
    users.defaultUserShell = lib.mkForce pkgs.zsh;
  };
}
