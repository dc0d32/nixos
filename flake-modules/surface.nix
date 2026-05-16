# Why: linux-surface project's patched kernel + iptsd userspace +
# Intel/Microsoft-Surface specific defaults (touch, pen, suspend,
# audio, wifi quirks, thermald profile). Without this, NixOS will
# boot on a Surface device, but touchscreen + pen won't work,
# suspend may crash, sleep can drain the battery in 6 hours, and
# Wi-Fi may be flaky.
#
# This module wraps nixos-hardware's microsoft-surface-pro-intel
# bundle (which itself imports microsoft-surface-common and the
# common/pc + common/cpu/intel modules). The surface-pro-intel
# module is explicitly noted by nixos-hardware to "work equally
# well on many other Surface models" — confirmed against Surface
# Laptop 3 (Intel). For an AMD-based Surface, swap the import to
# `microsoft-surface-laptop-amd`.
#
# Side effects (delivered by nixos-hardware):
#   - Replaces config.boot.kernelPackages with the linux-surface
#     patched 6.x LTS kernel. This OVERRIDES anything else the
#     host sets via `boot.kernelPackages = linuxPackages_latest;`
#     (mkOverride 50). Pull `linuxPackages_latest` out of the
#     bridge if you import this.
#   - services.iptsd.enable = true (touch / pen daemon).
#   - environment.systemPackages += [ surface-control ].
#   - services.thermald.enable = true with their config.
#   - Adds linux-surface's signing key for secure boot enrollment
#     (you still need to do the enrollment by hand; secure boot
#     should be OFF for v1 installs anyway).
#
# Retire when: NixOS upstream merges linux-surface patches into
# pkgs.linuxPackages_latest (unlikely — vendor-specific patches),
# OR you decommission the last Surface device.
{ inputs, ... }:
{
  flake.modules.nixos.surface = {
    imports = [
      inputs.nixos-hardware.nixosModules.microsoft-surface-pro-intel
    ];
  };
}
