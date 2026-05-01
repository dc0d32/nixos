# PLACEHOLDER hardware configuration for family-laptop.
#
# This is NOT a real hardware-configuration.nix. It exists so the flake
# evaluates and the toplevel derivation builds for smoke-testing on
# pb-x1. It is NOT BOOTABLE: the device UUID below is a sentinel and
# refers to nothing.
#
# REGENERATE THIS FILE on the actual family-laptop hardware before any
# `sudo nixos-rebuild switch`:
#
#   sudo nixos-generate-config --show-hardware-config \
#       > hosts/family-laptop/hardware-configuration.nix
#   git add hosts/family-laptop/hardware-configuration.nix
#
# After regeneration, also revisit flake-modules/hosts/family-laptop.nix
# for any host-specific tunables that depend on real hardware (CPU
# microcode vendor, GPU driver choice, swap device for hibernate, etc.).
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [
      (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # Sentinel UUID — all-zeros is invalid; do not boot with this.
  fileSystems."/" =
    {
      device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
      fsType = "ext4";
    };

  swapDevices = [ ];

  # Default to x86_64 so the flake evaluates on the dev box. Override on
  # the real hardware if it differs.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
