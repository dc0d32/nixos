# Hardware hacking — USB/serial/JTAG/flashing tools and the system-side
# udev rules + group memberships needed to access the devices without
# root.
#
# Cross-class footprint:
#   - flake.modules.nixos.hardware-hacking — udev rules, dialout/plugdev
#     group membership for `config.users.primary`. Retire individual
#     rules when upstream nixpkgs udev packages cover them.
#   - flake.modules.homeManager.hardware-hacking — user-space CLI tools
#     (usbutils, picocom, esptool, dfu-util, flashrom) and EDA (kicad,
#     Linux only).
#
# Pattern A enable: a host enables this feature by importing both
# contributed modules from its host file. There is no `enable` flag.
#
# Reads `config.users.primary` from the inner NixOS config (declared by
# flake-modules/users.nix). The previous version read the flake-parts
# singleton `config.host.user`, which is now retired.
{ ... }:
{
  flake.modules.nixos.hardware-hacking = { config, ... }: {
    # Add the user to groups needed for serial/USB device access.
    users.users.${config.users.primary}.extraGroups = [ "dialout" "plugdev" "uucp" ];

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

  flake.modules.homeManager.hardware-hacking = { pkgs, lib, ... }: {
    home.packages = with pkgs; [
      # USB / serial
      usbutils # lsusb
      picocom # minimal serial terminal
      screen # serial terminal (also general multiplexer)

      # Flashing / firmware
      esptool # ESP8266 / ESP32 flash tool
      dfu-util # STM32 and other DFU devices
      flashrom # SPI flash read/write via CH341A and others
    ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      # EDA — Linux only (no Darwin package)
      kicad
    ];
  };
}
