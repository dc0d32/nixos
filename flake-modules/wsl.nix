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
# Per-host configuration:
#   - `wsl.defaultUser` (NixOS option declared inside the inner
#     module): defaults to `config.users.primary` (declared by
#     flake-modules/users.nix). Override per-host if the WSL distro
#     should have a different login user than the rest of the system
#     uses. The default works for every WSL host in this repo.
#
# The mkForce overrides below remain because a WSL host might still
# import other feature modules (gpu, networking, audio, …) for code
# sharing; mkForce makes sure those layers don't accidentally
# re-enable on WSL even if their host file wires them in.
#
# Refactored to drop the
# flake-parts-level `wsl.defaultUser` singleton in favor of a proper
# per-NixOS-config option.
#
# Retire when: WSL2 is no longer the dev environment for any host, OR
#   Microsoft ships a NixOS-native WSL distribution (or upstream NixOS
#   absorbs the dc0d32/nixos-aarch64-wsl fork) that makes this wrapper
#   unnecessary.
{ ... }:
{
  flake.modules.nixos.wsl = { inputs, lib, pkgs, config, ... }: {
    imports = [ (inputs.nixos-wsl + "/wsl.nix") ];

    # The upstream WSL module declares `wsl.defaultUser` itself, so we
    # just set it to the host's primary user. (Older revisions of the
    # fork expected `defaultUser` as a specialArg / `_module.args`
    # entry; that's no longer the case.)
    config = {
      wsl.enable = true;
      wsl.defaultUser = lib.mkDefault config.users.primary;

      # --- Force-disable things our other modules might turn on ---
      # Base modules now use lib.mkDefault for policy options, so
      # plain values from the upstream WSL fork already win without
      # any intervention here. These mkForce entries are kept as
      # belt-and-suspenders: they guarantee the value even if a
      # host's configuration imports a feature module (e.g. niri,
      # pipewire) whose plain values would otherwise win.

      programs.niri.enable = lib.mkForce false;
      services.displayManager.ly.enable = lib.mkForce false;

      services.pipewire.enable = lib.mkForce false;
      services.pulseaudio.enable = lib.mkForce false;

      networking.networkmanager.enable = lib.mkForce false;

      # WSL manages DNS via /etc/resolv.conf itself (generateResolvConf
      # in wsl.conf). The upstream fork sets
      # `environment.etc."resolv.conf".enable = false` which collides
      # with NixOS's resolvconf service — disable it.
      networking.resolvconf.enable = lib.mkForce false;

      services.thermald.enable = lib.mkForce false;
      services.fwupd.enable = lib.mkForce false;

      hardware.graphics.enable = lib.mkForce false;
      services.xserver.videoDrivers = lib.mkForce [ ];

      # Make the wsl user's shell zsh so defaults line up with the
      # rest of the flake. Force both the per-user shell AND the
      # system default — the upstream WSL fork sets
      # users.defaultUserShell to bash at mkDefault priority, which
      # would otherwise collide with our users module setting zsh.
      users.users.${config.wsl.defaultUser}.shell = lib.mkForce pkgs.zsh;
      users.defaultUserShell = lib.mkForce pkgs.zsh;
    };
  };
}
