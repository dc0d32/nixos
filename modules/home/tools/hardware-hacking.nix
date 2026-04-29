{ pkgs, lib, variables, ... }:
# Hardware hacking tools: USB/serial, flashing, logic analysis, EDA.
# 3D CAD (FreeCAD) lives in modules/home/cad/freecad.nix — it carries
# its own preference pack and addons and shouldn't be coupled to the
# hardware-hacking flag.
let
  cfg = variables.hardwareHacking or { enable = false; };
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
lib.mkIf (cfg.enable or false) {
  home.packages = with pkgs; [
    # USB / serial
    usbutils        # lsusb
    picocom         # minimal serial terminal
    screen          # serial terminal (also general multiplexer)

    # Flashing / firmware
    esptool         # ESP8266 / ESP32 flash tool
    dfu-util        # STM32 and other DFU devices
    flashrom        # SPI flash read/write via CH341A and others

  ] ++ lib.optionals isLinux [
    # EDA — Linux only (no Darwin package)
    kicad
  ];
}
