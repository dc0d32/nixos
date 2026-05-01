# PLACEHOLDER hardware configuration for ah-1.
#
# This is NOT a real hardware-configuration.nix. It exists so the flake
# evaluates and the toplevel derivation builds for smoke-testing before
# the actual VM has been provisioned. It is NOT BOOTABLE: the device
# UUID below is a sentinel and refers to nothing.
#
# REGENERATE THIS FILE inside the actual ah-1 VM before the first
# `sudo nixos-rebuild switch`:
#
#   sudo nixos-generate-config --show-hardware-config \
#       > hosts/ah-1/hardware-configuration.nix
#   git add hosts/ah-1/hardware-configuration.nix
#
# Typical KVM/QEMU guest will detect virtio_blk + virtio_net + 9p
# (for shared folders) automatically. If the hypervisor exposes the
# disk as /dev/sda (SATA emulation) instead of /dev/vda (virtio-blk),
# adjust the boot loader stanza in flake-modules/hosts/ah-1.nix
# accordingly -- the bridge defaults to systemd-boot on UEFI which
# works for both.
{ lib, modulesPath, ... }:

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

  # Default to x86_64 so the flake evaluates on the dev box. Override
  # in the regenerated file if the actual VM is aarch64.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
