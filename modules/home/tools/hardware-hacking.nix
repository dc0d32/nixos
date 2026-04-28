{ pkgs, lib, variables, ... }:
# Hardware hacking tools: USB/serial, flashing, logic analysis, EDA, 3D CAD.
# GUI apps (KiCad, FreeCAD) are Linux-only. CLI tools work on WSL too.
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

  ] ++ lib.optionals isLinux [
    # EDA — Linux only (no Darwin package)
    kicad

    # 3D CAD — freecad-wayland for native Wayland rendering
    (pkgs.freecad-wayland or pkgs.freecad)
  ];
}
