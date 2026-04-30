# NixOS running inside WSL2 (including Windows on ARM via
# aarch64-linux).
#
# Uses github:dc0d32/nixos-aarch64-wsl, which publishes both
# x86_64-linux and aarch64-linux WSL rootfs tarballs. That flake
# exposes a file `wsl.nix` at its repo root (not a nixosModules
# output) and expects a `defaultUser` specialArg. We import the file
# directly and inject defaultUser via _module.args.
#
# Pattern A: WSL hosts opt in by importing this module. Bare-metal
# hosts simply don't import it, so the inputs.nixos-wsl flake is
# never imported either — desktop machines don't pay the eval cost.
#
# This means the legacy `lib.mkIf wslEnabled` and `lib.optionals
# wslEnabled` guards from modules/nixos/wsl.nix are gone: importing
# this module IS enabling.
#
# The mkForce overrides below remain because a WSL host might still
# import other feature modules (gpu, networking, audio, …) for code
# sharing; mkForce makes sure those layers don't accidentally
# re-enable on WSL even if their host file wires them in.
#
# Top-level option: `wsl.defaultUser`. Falls back to `host.user` when
# unset, matching the legacy variables.wsl.defaultUser behavior.
#
# Migrated from modules/nixos/wsl.nix.
{ lib, config, ... }:
let
  user = config.wsl.defaultUser;
in
{
  options.wsl.defaultUser = lib.mkOption {
    type = lib.types.str;
    default = config.host.user;
    defaultText = lib.literalExpression "config.host.user";
    description = "WSL distro's primary user, passed into the upstream WSL fork as defaultUser.";
  };

  config.flake.modules.nixos.wsl = { inputs, lib, pkgs, ... }: {
    imports = [ (inputs.nixos-wsl + "/wsl.nix") ];

    # The fork's wsl.nix reads `defaultUser` from module args.
    _module.args.defaultUser = user;

    # --- Force-disable things our other modules might turn on ---
    # Base modules now use lib.mkDefault for policy options, so plain
    # values from the upstream WSL fork already win without any
    # intervention here. These mkForce entries are kept as belt-and-
    # suspenders: they guarantee the value even if a host's
    # configuration imports a feature module (e.g. niri, pipewire)
    # whose plain values would otherwise win.

    programs.niri.enable = lib.mkForce false;
    services.displayManager.ly.enable = lib.mkForce false;

    services.pipewire.enable = lib.mkForce false;
    services.pulseaudio.enable = lib.mkForce false;

    networking.networkmanager.enable = lib.mkForce false;

    services.thermald.enable = lib.mkForce false;
    services.fwupd.enable = lib.mkForce false;

    hardware.graphics.enable = lib.mkForce false;
    services.xserver.videoDrivers = lib.mkForce [ ];

    # Make the wsl user's shell zsh so defaults line up with the rest
    # of the flake. Force both the per-user shell AND the system
    # default — the upstream WSL fork sets users.defaultUserShell to
    # bash at mkDefault priority, which would otherwise collide with
    # our users module (also mkDefault).
    users.users.${user}.shell = lib.mkForce pkgs.zsh;
    users.defaultUserShell = lib.mkForce pkgs.zsh;
  };
}
