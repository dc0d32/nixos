# PLACEHOLDER hardware configuration for ah-1.
#
# This is NOT a real hardware-configuration.nix. It exists so the flake
# evaluates and the toplevel derivation builds for smoke-testing before
# the actual VM has been provisioned. It carries no probed kernel
# modules and a hard NIXOS_ALLOW_PLACEHOLDER assertion that prevents
# accidental activation.
#
# Filesystem layout is owned by flake-modules/disko.nix and wired into
# this host via `config.flake.lib.diskoLayouts.vm { disk = "/dev/vda" }`
# in flake-modules/hosts/ah-1.nix. It is NOT in this file.
#
# REGENERATE THIS FILE inside the actual ah-1 VM before the first
# `sudo nixos-rebuild switch`. Use --no-filesystems so the generated
# fileSystems / swapDevices blocks aren't emitted (they would collide
# with the disko-generated ones):
#
#   sudo nixos-generate-config --no-filesystems --show-hardware-config \
#       > hosts/ah-1/hardware-configuration.nix
#   git add hosts/ah-1/hardware-configuration.nix
#
# Typical KVM/QEMU guest will detect virtio_blk + virtio_net + 9p
# (for shared folders) automatically. The VM disko layout assumes
# `/dev/vda` (virtio-blk); if Proxmox is configured to expose the
# disk as `/dev/sda` (SATA emulation) instead, change the `disk`
# argument in flake-modules/hosts/ah-1.nix.
{ config, lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # Fail-fast guard: refuse to evaluate while this placeholder is in
  # place, unless the operator explicitly opts in via the env var
  # NIXOS_ALLOW_PLACEHOLDER=1. The escape hatch keeps smoke-builds
  # (`nix build`, `nix flake check`) usable from a dev machine while
  # still aborting any unintentional `nixos-rebuild switch` on the
  # real VM. The whole assertion disappears automatically when
  # `nixos-generate-config --no-filesystems` overwrites this file.
  assertions = [{
    assertion = builtins.getEnv "NIXOS_ALLOW_PLACEHOLDER" == "1";
    message = ''
      hosts/ah-1/hardware-configuration.nix is still the PLACEHOLDER.
      Regenerate it inside the real ah-1 VM:

        sudo nixos-generate-config --no-filesystems --show-hardware-config \
            > hosts/ah-1/hardware-configuration.nix
        git add hosts/ah-1/hardware-configuration.nix

      then re-run nixos-rebuild. To smoke-build the placeholder
      from a dev machine, set NIXOS_ALLOW_PLACEHOLDER=1.
    '';
  }];

  # Default to x86_64 so the flake evaluates on the dev box. Override
  # in the regenerated file if the actual VM is aarch64.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
