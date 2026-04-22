{ config, lib, pkgs, inputs, variables, ... }:
# NixOS running inside WSL2 (including Windows on ARM via aarch64-linux).
#
# Uses github:dc0d32/nixos-aarch64-wsl, which publishes both x86_64-linux
# and aarch64-linux WSL rootfs tarballs.
#
# Enable with:
#   variables.wsl = {
#     enable = true;
#     defaultUser = "dc0d32";     # defaults to variables.user
#     startMenuLaunchers = true;  # generate Start-menu entries for GUI apps
#   };
#
# When enabled, this module:
#  - imports nixos-wsl's NixOS module
#  - force-disables desktop/login/graphics/power bits that don't apply in WSL
#  - lets WSL own the boot path (systemd-boot/grub would be wrong inside WSL)
#
# Windows-on-ARM: scaffold the host with `nix run .#new-host -- <name> --wsl`
# from inside the ARM WSL distro; the bootstrap script detects uname -m and
# sets variables.system = "aarch64-linux".
let
  cfg = variables.wsl or { enable = false; };
  wslUser = cfg.defaultUser or variables.user or "nixos";
in
lib.mkIf (cfg.enable or false) {
  imports = [ inputs.nixos-wsl.nixosModules.default ];

  wsl = {
    enable = true;
    defaultUser = wslUser;
    startMenuLaunchers = cfg.startMenuLaunchers or true;
    # nativeSystemd is on by default in modern nixos-wsl releases; keep it on
    # so user services (swayidle-style stuff, when relevant) could work.
    wslConf = {
      automount.root = "/mnt";
      network.generateHosts = true;
    };
  };

  # --- Disable things that don't belong inside WSL ---

  # WSL boots via its own init shim; no bootloader.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  boot.loader.grub.enable = lib.mkForce false;

  # No display manager or graphical compositor inside a base WSL install.
  # (You CAN run GUI apps via WSLg, but niri is not the right shell here.)
  programs.niri.enable = lib.mkForce false;
  services.displayManager.ly.enable = lib.mkForce false;

  # Audio: pipewire is unnecessary in WSL (WSLg provides its own).
  services.pipewire.enable = lib.mkForce false;
  services.pulseaudio.enable = lib.mkForce false;

  # Networking: WSL provides networking; NetworkManager + firewall conflict
  # with the host's networking stack.
  networking.networkmanager.enable = lib.mkForce false;
  networking.firewall.enable = lib.mkForce false;

  # Power/firmware doesn't apply inside WSL.
  services.thermald.enable = lib.mkForce false;
  services.fwupd.enable = lib.mkForce false;
  powerManagement.enable = lib.mkForce false;

  # GPU: WSL handles GPU passthrough (WSLg/DirectX) itself.
  hardware.graphics.enable = lib.mkForce false;
  services.xserver.videoDrivers = lib.mkForce [ ];

  # Don't try to manage users' passwords or groups the same way.
  # nixos-wsl sets up the default user; we keep system-level user decl minimal
  # by NOT declaring the user in configuration.nix when wsl.enable is true
  # (the host template handles this via lib.mkIf in hosts/_template later if needed).
  users.users.${wslUser}.shell = lib.mkForce pkgs.zsh;

  # tz and locale still apply, so those are left alone.
}
