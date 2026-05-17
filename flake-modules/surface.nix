# Why: linux-surface project's iptsd userspace + Intel/Microsoft-
# Surface specific defaults (sensors, firmware, thermald profile,
# Modern Standby tuning). Without this, NixOS will boot on a Surface
# device but touchscreen pen won't be daemonised, sensors won't
# expose readings, thermal will use the generic profile, etc.
#
# Two modules live here:
#
#   * `surface` (default) — userspace only. Pulls in nixos-hardware's
#     microsoft-surface-pro-intel bundle for firmware / iptsd /
#     thermald / sensors / surface-control, but forces
#     `boot.kernelPackages` back to whatever the host originally
#     wanted (linuxPackages_latest from egghead's bridge by default).
#     This avoids the ~30 minute local rebuild of linux-surface's
#     patched 6.x LTS kernel. Stock kernel covers most of SL3's
#     happy path: wired keyboard, trackpad, display, USB, Wi-Fi/BT,
#     audio (basic quality), suspend. The bits you lose without the
#     patched kernel: touchscreen, integrated pen, IPU3 camera, and
#     Type Cover bridge (irrelevant on Laptop 3 since its keyboard
#     is wired, but matters on Surface Pro / Surface Pro X).
#
#   * `surface-kernel` (opt-in) — re-enables the patched kernel by
#     undoing the mkForce override above. Adds 30-60min build time
#     on a fresh install (no upstream binary cache for the patched
#     build); strictly additive — must be imported alongside
#     `surface`, never on its own.
#
# Hosts pick: `surface` alone for fast install + basic Surface
# support, or `surface` + `surface-kernel` for the full hardware
# experience.
#
# Retire when: NixOS upstream merges linux-surface patches into
# pkgs.linuxPackages_latest (unlikely — vendor-specific patches),
# OR you decommission the last Surface device.
{ inputs, ... }:
{
  flake.modules.nixos.surface =
    { lib, pkgs, config, ... }:
    {
      imports = [
        inputs.nixos-hardware.nixosModules.microsoft-surface-pro-intel
      ];

      # Cross-module signal: `surface-kernel` flips this to true to
      # disable the kernel override below and keep nixos-hardware's
      # patched linux-surface kernel. See AGENTS.md "Cross-module
      # signals". Option lives on the inner NixOS-class config (not
      # the outer flake-parts config) because both modules co-evaluate
      # in the same NixOS module merge.
      options.surface.useKernel = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When true, leave nixos-hardware's microsoft-surface-common
          kernel assignment in place (the linux-surface patched
          kernel with full touch/pen/camera/Type-Cover support).
          When false (default), override it back to
          `pkgs.linuxPackages_latest` to skip the slow patched-
          kernel rebuild. Toggled on by importing the
          `surface-kernel` module alongside `surface`.
        '';
      };

      config = {
        # nixos-hardware's microsoft-surface-common sets
        # `boot.kernelPackages` as a plain assignment (priority 100).
        # When useKernel=false, force-override it back to the latest
        # mainline so we don't trigger the multi-hour patched-kernel
        # build on every install.
        boot.kernelPackages =
          lib.mkIf (!config.surface.useKernel)
            (lib.mkForce pkgs.linuxPackages_latest);

        # When the host enables LUKS, the wired keyboard on Surface
        # devices reaches the LUKS unlock prompt only if the Surface
        # Aggregator Module's HID glue is loaded in initrd. Stock
        # mainline (post-5.13) has the modules; nixos-generate-config
        # doesn't auto-detect them. Harmless if a module isn't
        # actually present in the running kernel — initrd just skips
        # missing ones.
        boot.initrd.kernelModules =
          lib.mkIf (config.boot.initrd.luks.devices or { } != { }) [
            "surface_aggregator"
            "surface_aggregator_registry"
            "surface_aggregator_hub"
            "surface_hid"
            "8250_dw"
          ];
      };
    };

  # Opt-in: brings back the patched linux-surface kernel by flipping
  # the cross-module signal. Strictly additive — must be imported
  # alongside `surface`, never on its own (the option is declared by
  # `surface`).
  flake.modules.nixos.surface-kernel = {
    surface.useKernel = true;
  };
}
