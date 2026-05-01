# PLACEHOLDER hardware configuration for pb-t480.
#
# This is NOT a real hardware-configuration.nix. It exists so the flake
# evaluates and the toplevel derivation builds for smoke-testing on
# pb-x1. It is NOT BOOTABLE: the device UUID below is a sentinel and
# refers to nothing.
#
# REGENERATE THIS FILE on the actual pb-t480 hardware before any
# `sudo nixos-rebuild switch`:
#
#   sudo nixos-generate-config --show-hardware-config \
#       > hosts/pb-t480/hardware-configuration.nix
#   git add hosts/pb-t480/hardware-configuration.nix
#
# After regeneration, also revisit flake-modules/hosts/pb-t480.nix
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

  # Fail-fast guard: refuse to evaluate while the sentinel UUID is in
  # place, unless the operator explicitly opts in via the env var
  # NIXOS_ALLOW_PLACEHOLDER=1. The escape hatch keeps smoke-builds
  # (`nix build`, `nix flake check`) usable from a dev machine while
  # still aborting any unintentional `nixos-rebuild switch` on the
  # real hardware. The whole assertion disappears automatically when
  # `nixos-generate-config` overwrites this file.
  assertions = [{
    assertion = config.fileSystems."/".device
      != "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000"
      || builtins.getEnv "NIXOS_ALLOW_PLACEHOLDER" == "1";
    message = ''
      hosts/pb-t480/hardware-configuration.nix is still the
      PLACEHOLDER (root device is the all-zeros sentinel UUID).
      Regenerate it on the real pb-t480 hardware:

        sudo nixos-generate-config --show-hardware-config \
            > hosts/pb-t480/hardware-configuration.nix
        git add hosts/pb-t480/hardware-configuration.nix

      then re-run nixos-rebuild. To smoke-build the placeholder
      from a dev machine, set NIXOS_ALLOW_PLACEHOLDER=1.
    '';
  }];

  # Default to x86_64 so the flake evaluates on the dev box. Override on
  # the real hardware if it differs.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
