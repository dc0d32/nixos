# PLACEHOLDER hardware configuration for nixtest.
#
# NOT a real hardware-configuration.nix. It exists so the flake evaluates
# and the toplevel builds for smoke-testing before the scratch VM is
# provisioned. Filesystem layout is owned by flake-modules/disko.nix
# (the `vm` factory, /dev/vda) wired in flake-modules/hosts/nixtest.nix —
# not here.
#
# REGENERATE inside the real VM before the first `nixos-rebuild switch`
# (nixos-anywhere does this automatically via --generate-hardware-config;
# or run manually):
#
#   sudo nixos-generate-config --no-filesystems --show-hardware-config \
#       > hosts/nixtest/hardware-configuration.nix
#   git add hosts/nixtest/hardware-configuration.nix
#
# A typical KVM/QEMU guest auto-detects virtio_blk + virtio_net.
{ lib, modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # Fail-fast guard: refuse to evaluate `system.build.toplevel` while this
  # placeholder is in place, unless NIXOS_ALLOW_PLACEHOLDER=1 is set. Keeps
  # smoke-builds usable from a dev box while blocking an accidental
  # activation on the real VM. Disappears when nixos-generate-config
  # overwrites this file.
  assertions = [{
    assertion = builtins.getEnv "NIXOS_ALLOW_PLACEHOLDER" == "1";
    message = ''
      hosts/nixtest/hardware-configuration.nix is still the PLACEHOLDER.
      Regenerate it inside the real nixtest VM, then re-run. To smoke-build
      the placeholder from a dev machine, set NIXOS_ALLOW_PLACEHOLDER=1.
    '';
  }];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
