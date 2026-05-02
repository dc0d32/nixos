# Hardware hacking — USB/serial/JTAG/flashing tools and the system-side
# udev rules + group memberships needed to access the devices without
# root.
#
# Cross-class footprint:
#   - flake.modules.nixos.hardware-hacking — udev rules, dialout/plugdev
#     group membership for `config.users.primary`, plus any users named
#     in `hardware-hacking.extraUsers` (used on pb-t480 to grant the
#     kid accounts USB device access for robotics work). Retire
#     individual rules when upstream nixpkgs udev packages cover them.
#   - flake.modules.homeManager.hardware-hacking — user-space CLI tools
#     only (usbutils, picocom, screen, esptool, dfu-util, flashrom).
#     KiCad lives in its own module flake-modules/kicad.nix since
#     2026-05-02 — see that file for why.
#
# Pattern A enable: a host enables this feature by importing both
# contributed modules from its host file. There is no top-level
# `enable` flag; the only host-tunable option is `extraUsers` (see
# below).
#
# Reads `config.users.primary` from the inner NixOS config (declared by
# flake-modules/users.nix). The previous version read the flake-parts
# singleton `config.host.user`, which is now retired.
#
# Retire when: USB/serial/JTAG/firmware-flashing work is no longer done
#   from any host in the repo (e.g. all hardware hacking moves to a
#   dedicated bench machine outside this flake).
{ config, lib, ... }:
{
  # Per-host knob: extra usernames (besides users.primary) that should
  # land in dialout/plugdev/uucp. Used on pb-t480 so the kid accounts
  # can flash RP2040 / ESP boards without an adult logging in. Default
  # empty so single-user hosts (pb-x1, ah-1) get the existing behavior.
  options.hardware-hacking.extraUsers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "m" "s" ];
    description = ''
      Additional system usernames (besides `users.primary`) that should
      be added to the dialout/plugdev/uucp groups so they can access
      USB-serial / DFU / programmer devices without sudo. Imported by
      flake.modules.nixos.hardware-hacking.
    '';
  };

  # Read the option from the OUTER flake-parts config (AGENTS.md: "let-bind
  # cfg from the outer flake-parts config"). The inner NixOS module below
  # shadows `config` with the per-system NixOS config, so we capture
  # `cfg` here at outer scope.
  config.flake.modules.nixos.hardware-hacking =
    let
      cfg = config.hardware-hacking;
    in
    { config, lib, ... }: {
      # Add the primary user + any extras to groups needed for
      # serial/USB device access. genAttrs builds users.users.<name>
      # for every name in (primary :: extras) without duplication.
      # `extraGroups` accumulates with anything else the per-user
      # config sets elsewhere (e.g. wheel for `p`), it doesn't replace.
      users.users =
        let
          targets = lib.unique ([ config.users.primary ] ++ cfg.extraUsers);
          groups = [ "dialout" "plugdev" "uucp" ];
        in
        lib.genAttrs targets (_: { extraGroups = groups; });

      services.udev.extraRules = ''
        # CP210x USB-serial (common on ESP32/ESP8266 devboards)
        SUBSYSTEM=="usb", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", MODE="0666", GROUP="dialout"

        # CH340/CH341 USB-serial
        SUBSYSTEM=="usb", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666", GROUP="dialout"
        SUBSYSTEM=="usb", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="5523", MODE="0666", GROUP="dialout"

        # FTDI FT232
        SUBSYSTEM=="usb", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", MODE="0666", GROUP="dialout"
        SUBSYSTEM=="usb", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", MODE="0666", GROUP="dialout"
        SUBSYSTEM=="usb", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6011", MODE="0666", GROUP="dialout"

        # ESP32-S3 / ESP32-C3 native USB (JTAG + CDC)
        SUBSYSTEM=="usb", ATTRS{idVendor}=="303a", MODE="0666", GROUP="dialout"

        # STM32 DFU
        SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", MODE="0666", GROUP="plugdev"

        # Raspberry Pi RP2040 (UF2 bootloader)
        SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", MODE="0666", GROUP="plugdev"
      '';
    };

  config.flake.modules.homeManager.hardware-hacking = { pkgs, ... }: {
    home.packages = with pkgs; [
      # USB / serial
      usbutils # lsusb
      picocom # minimal serial terminal
      screen # serial terminal (also general multiplexer)

      # Flashing / firmware
      esptool # ESP8266 / ESP32 flash tool
      dfu-util # STM32 and other DFU devices
      flashrom # SPI flash read/write via CH341A and others
    ];
    # KiCad moved to flake-modules/kicad.nix on 2026-05-02 so that
    # bundles which want the flashing CLIs (e.g. the kid bundle on
    # pb-t480) don't have to inherit ~1 GB of EDA closure they don't
    # use. Adult `desktop` bundle picks up KiCad from there directly.
  };
}
