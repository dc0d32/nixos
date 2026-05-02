# KiCad — open-source EDA suite (schematic capture + PCB layout +
# 3D viewer). Extracted from flake-modules/hardware-hacking.nix on
# 2026-05-02 because the audience for KiCad and the audience for
# the USB/serial/flashing CLIs no longer overlap exactly: the kid
# accounts on pb-t480 do robotics (RP2040 + ESP) so they want the
# flashing tools, but they don't currently do PCB design and so
# don't need the ~1 GB KiCad closure (kicad-base + footprints +
# packages3d + symbols + templates).
#
# Pattern A: bundles opt in by importing this module. The adult
# `desktop` bundle imports it; the `kid` bundle does not.
#
# Linux-only: no Darwin package. Guarded by lib.optionals so an
# accidental import on a non-Linux HM config is a no-op rather than
# a build break.
#
# Retire when: no host in the flake does PCB layout work, OR KiCad
#   moves into a larger "EDA suite" bundle alongside other tools.
{
  flake.modules.homeManager.kicad = { pkgs, lib, ... }: {
    home.packages = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      pkgs.kicad
    ];
  };
}
