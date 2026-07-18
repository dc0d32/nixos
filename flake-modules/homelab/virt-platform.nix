# virt-platform.nix — platform-level virtualization enablement for a
# homelab hypervisor node: IOMMU (VT-d/AMD-Vi), VFIO, nested virt, and
# KVM tuning. This is the CAPABILITY layer, distinct from `virt-host`
# (which turns on libvirtd + puts the operator in the libvirtd group).
#
# Why a separate module from virt-host:
#   A host that runs guests via microvm.nix only (no libvirtd) must NOT
#   import virt-host. But it still wants IOMMU/VFIO/nested so its microVMs
#   can eventually do PCI passthrough and run nested guests. A libvirt host
#   wants both. Splitting the platform knobs out lets each host opt into
#   exactly what it needs.
#
# What it does (all inert until `homelab.virtPlatform.enable = true`):
#   - IOMMU on: `intel_iommu=on` / `amd_iommu=on` (auto by CPU vendor) plus
#     `iommu=pt` (passthrough/identity domain — near-zero DMA-remap overhead
#     for host-owned devices; VFIO overrides per-device when it claims one).
#     Takes effect on the NEXT REBOOT (kernel cmdline).
#   - VFIO stack loaded (`vfio_pci vfio_iommu_type1 vfio`) so a device can be
#     bound to vfio-pci later without another rebuild. Binding SPECIFIC
#     devices (isolating them from the host at boot) is deliberately NOT done
#     here — do that per-host via `boot.kernelParams = [ "vfio-pci.ids=..." ]`
#     or an initrd bind when you actually pass a device through.
#   - Nested virt made explicit (`kvm_intel`/`kvm_amd` `nested=1`) so guests
#     can themselves run KVM (e.g. a nested test hypervisor).
#   - `homelab.virtPlatform.vendor` auto-detects from the host's
#     `nixpkgs.hostPlatform`/CPU; override only for cross-build edge cases.
#
# Retire when: nixpkgs grows a first-class `hardware.iommu.enable` that
#   covers vendor autodetect + VFIO + pt in one option, or the homelab
#   stops doing PCI passthrough / nested virt.
{ lib, ... }:
{
  flake.modules.nixos.virt-platform = { config, lib, pkgs, ... }:
    let
      cfg = config.homelab.virtPlatform;
      # Detect x86 CPU vendor from the host's own /proc at eval time isn't
      # possible (pure eval), so key off the declared marker with an Intel
      # default (both current homelab x86 hosts are Intel). Hosts on AMD set
      # `homelab.virtPlatform.vendor = "amd"`.
      isIntel = cfg.vendor == "intel";
      isAmd = cfg.vendor == "amd";
    in
    {
      options.homelab.virtPlatform = {
        enable = lib.mkEnableOption
          "platform virtualization: IOMMU + VFIO + nested virt";

        vendor = lib.mkOption {
          type = lib.types.enum [ "intel" "amd" ];
          default = "intel";
          description = ''
            CPU vendor, selecting the IOMMU kernel param
            (`intel_iommu=on` vs `amd_iommu=on`) and the KVM module
            (`kvm_intel` vs `kvm_amd`). Both current homelab x86 hosts are
            Intel; set to "amd" on an AMD host.
          '';
        };

        passthroughPt = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Add `iommu=pt` (identity/passthrough domain) so host-owned
            devices skip DMA remapping overhead. VFIO still fully isolates
            any device it claims. Turn off only if a device misbehaves in
            pt mode.
          '';
        };

        loadVfio = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Load the VFIO module stack at boot so devices can be bound to
            vfio-pci later without a rebuild. Does NOT bind any device by
            itself.
          '';
        };

        vfioPciIds = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "1002:6608" "1002:aab0" ];
          description = ''
            PCI `vendor:device` IDs to bind to vfio-pci at boot (via the
            `vfio-pci.ids=` kernel param), claiming them away from their
            native host driver so a guest can take them by PCI passthrough.
            NOTE: matches ALL devices with these IDs — fine when every card
            of that model is meant for passthrough. Pair with
            `boot.blacklistedKernelModules` for the native driver if it would
            otherwise race vfio-pci for the device. Takes effect on reboot.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [{
          assertion = config.nixpkgs.hostPlatform.isx86_64;
          message =
            "homelab.virtPlatform is x86_64-only (IOMMU/VFIO/KVM); do not "
            + "enable it on an aarch64 host.";
        }];

        boot.kernelParams =
          (lib.optional isIntel "intel_iommu=on")
          ++ (lib.optional isAmd "amd_iommu=on")
          ++ (lib.optional cfg.passthroughPt "iommu=pt")
          ++ (lib.optional (cfg.vfioPciIds != [ ])
            "vfio-pci.ids=${lib.concatStringsSep "," cfg.vfioPciIds}");

        # Ensure vfio-pci is present early enough to claim the IDs before the
        # native driver probes them.
        boot.initrd.kernelModules =
          lib.optionals (cfg.loadVfio && cfg.vfioPciIds != [ ]) [ "vfio_pci" ];

        # VFIO stack available for later device binding.
        boot.kernelModules = lib.optionals cfg.loadVfio [
          "vfio"
          "vfio_pci"
          "vfio_iommu_type1"
        ];

        # Make nested virt explicit (nixpkgs already defaults it on, but
        # pin it so a future default flip doesn't silently disable it).
        boot.extraModprobeConfig =
          lib.optionalString isIntel "options kvm_intel nested=1\n"
          + lib.optionalString isAmd "options kvm_amd nested=1\n";
      };
    };
}
