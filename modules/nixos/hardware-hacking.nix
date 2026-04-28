{ lib, variables, ... }:
# System-level hardware hacking support: udev rules and group membership.
# Covers CP210x, CH340, FTDI, STM32 DFU, ESP* USB-serial and USB-JTAG adapters.
# Retire individual rules when upstream nixpkgs udev packages cover them.
let cfg = variables.hardwareHacking or { enable = false; };
in
lib.mkIf (cfg.enable or false) {
  # Add the user to groups needed for serial/USB device access.
  users.users.${variables.user}.extraGroups = [ "dialout" "plugdev" "uucp" ];

  # udev rules so devices are accessible without root.
  services.udev.packages = with lib; [
    # Arduino / generic USB-serial (CH340, CP210x, FTDI) — covered by nixpkgs
  ];

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
}
