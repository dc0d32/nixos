# PLACEHOLDER hardware configuration for m-pc.
#
# This is NOT a real hardware-configuration.nix. It exists so the flake
# evaluates and the toplevel derivation builds for smoke-testing before
# the actual machine has been provisioned. It is NOT BOOTABLE: the device
# UUID below is a sentinel and refers to nothing.
#
# REGENERATE THIS FILE on the actual m-pc box before the first
# `sudo nixos-rebuild switch`:
#
#   sudo nixos-generate-config --show-hardware-config \
#       > hosts/m-pc/hardware-configuration.nix
#   git add hosts/m-pc/hardware-configuration.nix
#
# The host is a Compaq Pro 4300 SFF (3rd-gen Ivy Bridge i3, 8 GiB RAM,
# AMD Radeon Pro WX 2100 discrete GPU — formerly branded FirePro W2100
# before AMD's 2017 rebrand, same silicon either way). nixos-generate-
# config will pick up the right kernel modules (ahci for SATA, amdgpu
# for the WX 2100 if a recent kernel is in use, e1000e for the onboard
# Intel NIC, snd_hda_intel for the Realtek HD-audio codec driving the
# built-in chassis speaker, etc.) on the real hardware.
#
# Bootloader: this generation of OptiPlex/Compaq SFFs typically ships
# BIOS-only (no UEFI). If the regenerated hardware config sets
# `boot.loader.systemd-boot.enable = false` and the host bridge default
# of systemd-boot doesn't boot, override with:
#
#   boot.loader.grub = {
#     enable = true;
#     device = "/dev/sda";   # or whichever disk
#   };
#   boot.loader.systemd-boot.enable = lib.mkForce false;
#
# inside `configurations.nixos.m-pc.module` in flake-modules/hosts/m-pc.nix.
{ config, lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # Sentinel UUID -- all-zeros is invalid; do not boot with this.
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    fsType = "ext4";
  };

  swapDevices = [ ];

  # Fail-fast guard: refuse to evaluate while the sentinel UUID is in
  # place, unless the operator explicitly opts in via the env var
  # NIXOS_ALLOW_PLACEHOLDER=1. The escape hatch keeps smoke-builds
  # (`nix build`, `nix flake check`) usable from a dev machine while
  # still aborting any unintentional `nixos-rebuild switch` on the
  # real machine. The whole assertion disappears automatically when
  # `nixos-generate-config` overwrites this file.
  assertions = [{
    assertion = config.fileSystems."/".device
      != "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000"
      || builtins.getEnv "NIXOS_ALLOW_PLACEHOLDER" == "1";
    message = ''
      hosts/m-pc/hardware-configuration.nix is still the PLACEHOLDER
      (root device is the all-zeros sentinel UUID). Regenerate it
      on the real m-pc:

        sudo nixos-generate-config --show-hardware-config \
            > hosts/m-pc/hardware-configuration.nix
        git add hosts/m-pc/hardware-configuration.nix

      then re-run nixos-rebuild. To smoke-build the placeholder
      from a dev machine, set NIXOS_ALLOW_PLACEHOLDER=1.
    '';
  }];

  # Default to x86_64 so the flake evaluates on the dev box. The Compaq
  # 4300 SFF is x86_64 (Ivy Bridge), so the regenerated file will keep
  # this value.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
