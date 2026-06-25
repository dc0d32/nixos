# Hardware hacking — USB/serial/JTAG/flashing tools and the system-side
# udev rules + group memberships needed to access the devices without
# root.
#
# Cross-class footprint:
#   - flake.modules.nixos.hardware-hacking — udev rules, dialout/plugdev
#     group membership for `config.users.primary`, plus any users named
#     in the per-host NixOS option `hardware-hacking.extraUsers` (used
#     on pb-t480 to grant the kid accounts USB device access for
#     robotics work). Retire individual rules when upstream nixpkgs
#     udev packages cover them.
#   - flake.modules.homeManager.hardware-hacking — user-space CLI tools
#     only. Serial/USB + flashing (usbutils, picocom, screen, esptool,
#     dfu-util, flashrom) PLUS the embedded dev toolchain to build &
#     debug firmware (gcc-arm-embedded, gdb, openocd, probe-rs-tools,
#     picotool, avrdude, arduino-cli). KiCad lives in its own module
#     flake-modules/kicad.nix since 2026-05-02 — see that file for why.
#
# Pattern A enable: a host enables this feature by importing both
# contributed modules from its host file. There is no top-level
# `enable` flag.
#
# Why `extraUsers` is a NixOS option (not a flake-parts top-level
# option): flake-parts top-level options are SHARED across every host
# in the flake. Setting `hardware-hacking.extraUsers = [ "m" "s" ]` on
# pb-t480 would leak into pb-x1's eval and try to add phantom `m`/`s`
# accounts there. Declaring the option inside the NixOS module makes
# it per-host: pb-t480 sets it inside its NixOS config body, pb-x1
# leaves it at its `[ ]` default, no cross-contamination.
#
# Reads `config.users.primary` from the inner NixOS config (declared by
# flake-modules/users.nix). The previous version read the flake-parts
# singleton `config.host.user`, which is now retired.
#
# Retire when: USB/serial/JTAG/firmware-flashing work is no longer done
#   from any host in the repo (e.g. all hardware hacking moves to a
#   dedicated bench machine outside this flake).
{
  flake.modules.nixos.hardware-hacking = { config, lib, pkgs, ... }: {
    options.hardware-hacking.extraUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "m" "s" ];
      description = ''
        Additional system usernames (besides `users.primary`) that
        should be added to the dialout/plugdev/uucp groups so they can
        access USB-serial / DFU / programmer devices without sudo.
        Each name must correspond to a user defined elsewhere in this
        host's NixOS config (typically the host bridge).
      '';
    };

    config = {
      # Add the primary user + any extras to groups needed for
      # serial/USB device access. genAttrs builds users.users.<name>
      # for every name in (primary :: extras) without duplication.
      # `extraGroups` accumulates with anything else the per-user
      # config sets elsewhere (e.g. wheel for `p`); it does not replace.
      users.users =
        let
          targets = lib.unique (
            [ config.users.primary ] ++ config.hardware-hacking.extraUsers
          );
          groups = [ "dialout" "plugdev" "uucp" ];
        in
        lib.genAttrs targets (_: { extraGroups = groups; });

      # `plugdev` is referenced by the udev rules below and by the
      # accounts' extraGroups, but NixOS does not create it by default —
      # declare it so those references resolve instead of silently
      # leaving devices root-owned (a stealth "needs sudo to flash").
      users.groups.plugdev = { };

      services.udev.extraRules = ''
        # TAG+="uaccess": grant the user with the active local (seat)
        # session a per-login ACL on the device, so flashing/debugging
        # NEVER needs sudo and works for whoever is physically at the
        # machine (incl. the kids), independent of group membership.
        # GROUP=/MODE= are a fallback for non-seat (e.g. SSH) sessions.
        #
        # USB-serial bridges. The kernel already puts the resulting
        # /dev/ttyUSB*,ttyACM* in group "dialout"; these also open the
        # raw usb node and add the uaccess ACL.
        SUBSYSTEM=="usb", ATTRS{idVendor}=="10c4", MODE="0660", GROUP="dialout", TAG+="uaccess"  # Silicon Labs CP210x
        SUBSYSTEM=="usb", ATTRS{idVendor}=="1a86", MODE="0660", GROUP="dialout", TAG+="uaccess"  # QinHeng CH34x/CH910x
        SUBSYSTEM=="usb", ATTRS{idVendor}=="0403", MODE="0660", GROUP="dialout", TAG+="uaccess"  # FTDI
        SUBSYSTEM=="usb", ATTRS{idVendor}=="303a", MODE="0660", GROUP="dialout", TAG+="uaccess"  # Espressif native USB (ESP32-S2/S3/C3)

        # Boards / programmers flashed or debugged over raw USB.
        SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", MODE="0660", GROUP="plugdev", TAG+="uaccess"  # Raspberry Pi RP2040 (UF2/picotool/debugprobe)
        SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", MODE="0660", GROUP="plugdev", TAG+="uaccess"  # STM32 DFU + ST-Link
        SUBSYSTEM=="usb", ATTRS{idVendor}=="0d28", MODE="0660", GROUP="plugdev", TAG+="uaccess"  # ARM mbed / DAPLink (BBC micro:bit)
        SUBSYSTEM=="usb", ATTRS{idVendor}=="2341", MODE="0660", GROUP="plugdev", TAG+="uaccess"  # Arduino
        SUBSYSTEM=="usb", ATTRS{idVendor}=="239a", MODE="0660", GROUP="plugdev", TAG+="uaccess"  # Adafruit
        SUBSYSTEM=="usb", ATTRS{idVendor}=="1366", MODE="0660", GROUP="plugdev", TAG+="uaccess"  # SEGGER J-Link
      '';

      # OpenOCD ships a comprehensive, maintained udev ruleset for debug
      # probes (ST-Link, J-Link, CMSIS-DAP, FTDI-JTAG, …) with uaccess +
      # plugdev — so we don't hand-maintain every programmer's VID:PID.
      services.udev.packages = [ pkgs.openocd ];
    };
  };

  flake.modules.homeManager.hardware-hacking = { pkgs, ... }: {
    home.packages = with pkgs; [
      # USB / serial
      usbutils # lsusb
      picocom # minimal serial terminal
      screen # serial terminal (also general multiplexer)

      # Flashing / firmware
      esptool # ESP8266 / ESP32 flash tool
      dfu-util # STM32 and other DFU devices
      flashrom # SPI flash read/write via CH341A and others

      # ── Embedded development toolchain (compile + debug) ──────────
      # The tools above only flash prebuilt firmware; these let you
      # actually BUILD and DEBUG it from the terminal. Curated to the
      # targets this repo's flash tools + udev rules already cover
      # (ARM Cortex-M: STM32/RP2040/nRF; RP2040 specifically; AVR /
      # classic Arduino), plus the Arduino CLI ecosystem that's the
      # friendliest on-ramp.
      gcc-arm-embedded # arm-none-eabi-{gcc,g++,gdb,…}: STM32/RP2040/nRF
      openocd # on-chip debug + flashing over SWD/JTAG
      probe-rs-tools # modern Rust probe tool (RP2040/STM32 flash+debug)
      picotool # RP2040 UF2/info/reboot helper
      avrdude # AVR programmer (Arduino Uno/Nano classic)
      arduino-cli # Arduino ecosystem build/upload from the terminal
    ];
    # KiCad moved to flake-modules/kicad.nix on 2026-05-02 so that
    # bundles which want the flashing CLIs (e.g. the kid bundle on
    # pb-t480) don't have to inherit ~1 GB of EDA closure they don't
    # use. Adult `desktop` bundle picks up KiCad from there directly.
  };
}
