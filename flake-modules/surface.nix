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
#     wanted (linuxPackages_latest by default on bare-metal hosts).
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

      config =
        let
          luksOn = config.boot.initrd.luks.devices or { } != { };

          # The full keyboard chain on Surface Laptop 3 (10th-gen
          # Ice Lake, SAM-attached HID keyboard):
          #
          #   8250_dw                 ──> DesignWare UART (the bus
          #                                SAM rides on)
          #   pinctrl_icelake         ──> SoC pinctrl driver, owns the
          #                                GPIO IRQ lines SAM uses
          #   surface_aggregator      ──> SAM core (ACPI-matched)
          #   surface_aggregator_registry,
          #   surface_aggregator_hub  ──> enumerate SAM child devices
          #   surface_hid_core,
          #   surface_hid             ──> HID-over-SAM glue producing
          #                                /dev/input/eventN
          #   hid, hid_generic        ──> generic HID core (usually
          #                                built-in but listing in
          #                                availableKernelModules is
          #                                harmless and explicit)
          #   evdev                   ──> input layer cryptsetup reads
          #                                from to grab keypresses
          #
          # Without ALL of these chained correctly, the LUKS prompt
          # gets no keystrokes. Listing in availableKernelModules
          # is what actually makes things work in systemd-stage-1:
          # udev matches the modalias of each newly-enumerated device
          # and autoloads the right driver. Listing in kernelModules
          # too is belt-and-suspenders for the script-stage-1 path
          # (still used on non-LUKS hosts; harmless on
          # systemd-stage-1).
          surfaceKbdModules = [
            "8250_dw"
            "pinctrl_icelake"
            "surface_aggregator"
            "surface_aggregator_registry"
            "surface_aggregator_hub"
            "surface_hid_core"
            "surface_hid"
            "hid"
            "hid_generic"
            "evdev"
          ];
        in
        {
          # nixos-hardware's microsoft-surface-common sets
          # `boot.kernelPackages` as a plain assignment (priority 100).
          # When useKernel=false, force-override it back to the latest
          # mainline so we don't trigger the multi-hour patched-kernel
          # build on every install.
          boot.kernelPackages =
            lib.mkIf (!config.surface.useKernel)
              (lib.mkForce pkgs.linuxPackages_latest);

          # systemd-stage-1 is the load-bearing fix for the keyboard
          # problem. The script-based initrd (NixOS default) does NOT
          # run a udev loop during the LUKS prompt — it just calls
          # cryptsetup luksOpen and blocks on its TTY read. That
          # leaves SAM platform devices unbound to their drivers even
          # if the modules are force-loaded, because nothing fires
          # the ACPI modalias match. systemd-stage-1 runs a proper
          # udev, brings up the full input stack the same way the
          # booted system does, and the keyboard actually works.
          #
          # mkIf-gated on LUKS being in use because hosts without
          # encryption never see a prompt in initrd and don't need
          # the larger systemd-stage-1 footprint.
          boot.initrd.systemd.enable = lib.mkIf luksOn true;

          # When LUKS is on, expose the Surface keyboard chain to
          # both initrd module-resolution paths. availableKernelModules
          # is what udev matches against; kernelModules force-loads
          # them in case something in the chain isn't tagged with
          # the right modalias.
          boot.initrd.availableKernelModules =
            lib.mkIf luksOn surfaceKbdModules;
          boot.initrd.kernelModules =
            lib.mkIf luksOn surfaceKbdModules;

          # Power button quirk: on Surface laptops the same physical
          # key wakes the machine AND emits a KEY_POWER event after
          # resume — logind sees the event with HandlePowerKey="suspend"
          # and immediately re-suspends within a couple of seconds of
          # waking up. Symptom: power-button-to-wake shows the
          # lockscreen briefly then puts the laptop back to sleep.
          # Setting "ignore" here means the *only* way to suspend is
          # the lid switch, an explicit `systemctl suspend` from the
          # CLI or a waybar tray action, or idled. That's an
          # acceptable trade on a Surface, since the power button
          # was never reliable as an explicit-suspend trigger anyway.
          services.logind.settings.Login.HandlePowerKey = "ignore";
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
