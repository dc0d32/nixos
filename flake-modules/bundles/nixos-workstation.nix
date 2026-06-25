# NixOS bundle: workstation.
#
# The bare-metal graphical-laptop/desktop core — the set of NixOS
# feature modules that every full-fat workstation host imports
# identically. Extracted on 2026-06-25 because pb-x1, m-pc and pb-t480
# each hand-listed the same ~19 modules in their `imports`, which
# invited drift. This is the intersection of the three; per-host extras
# (biometrics, face-unlock, hardware-hacking, timekpr, chrome-managed,
# nixos-hardware, disko/hardware-configuration) stay in the bridge.
#
# Importing IS enabling (AGENTS.md): a host splices this list into its
# NixOS `imports` to opt into the whole core at once:
#   imports = config.flake.lib.bundles.nixos.workstation ++ [ … ];
#
# Members:
#   impermanence backup gpu power networking nix-settings system-utils
#   users fonts locale battery audio bluetooth boot kernel-latest
#   file-manager login-ly niri lockscreen home-manager-bootstrap
#
# Published under flake.lib.bundles.nixos.workstation (lists live under
# flake.lib because flake-parts only recognizes a fixed set of top-level
# flake.* attrs; lib is the documented escape hatch).
#
# Retire when: the flake stops having bare-metal graphical hosts, OR the
#   three workstation hosts diverge enough that a shared core no longer
#   earns its keep.
{ config, ... }:
{
  flake.lib.bundles.nixos.workstation = with config.flake.modules.nixos; [
    # Root-rollback impermanence + daily restic backup of /persist.
    impermanence
    backup

    gpu
    power
    networking
    nix-settings
    system-utils
    users
    fonts
    locale
    battery
    audio
    bluetooth
    boot
    kernel-latest
    file-manager
    login-ly
    niri
    lockscreen
    home-manager-bootstrap
  ];
}
