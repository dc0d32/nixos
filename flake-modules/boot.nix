# Bootloader policy — systemd-boot defaults shared by every UEFI host.
#
# Pattern A: hosts opt in by importing this module. Headless / non-UEFI
# hosts (e.g. a future BIOS VM) simply don't import it and define their
# own boot.loader.* settings instead.
#
# Why a dedicated module rather than per-host copies: every UEFI host
# in the flake had the same three lines (enable, canTouchEfiVariables,
# consoleMode) duplicated in its host bridge. Adding configurationLimit
# would be a fourth duplicated line. One shared module is the dendritic
# answer; hosts override individual fields with mkForce / re-assignment
# if they need different policy.
#
# All scalars use lib.mkDefault so a host that does import this module
# can still override individual knobs without mkForce.
#
# What's set:
#   - systemd-boot.enable: standard UEFI boot via systemd-boot.
#   - efi.canTouchEfiVariables: lets the installer/switch register the
#     boot entry with the firmware. Required for first install; safe to
#     leave true thereafter.
#   - systemd-boot.consoleMode = "max": ask firmware for the highest
#     framebuffer mode it supports. The kernel inherits this mode for
#     its boot log and TTYs, so the cozette6x13 console font (set in
#     flake-modules/fonts.nix) renders at native panel resolution
#     instead of being blown up by the firmware's default low-res mode.
#   - systemd-boot.configurationLimit = 15: cap the boot menu at the 15
#     most recent generations. Older generations remain in the system
#     profile (visible via `nix-env -p /nix/var/nix/profiles/system
#     --list-generations`) and are still rollback-targets via that
#     profile, but they don't clutter the boot menu. The two-stage GC
#     timer in nix-settings.nix prunes the underlying generations on a
#     separate schedule (weekly: drop >14d old, then trim to 15 newest)
#     — kept matched at 15 so the menu and the on-disk count agree at
#     steady state.
#
# Retire when: NixOS upstream defaults converge on these settings, OR
#   the flake migrates off systemd-boot.
{ ... }:
{
  flake.modules.nixos.boot = { lib, ... }: {
    boot.loader.systemd-boot.enable = lib.mkDefault true;
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
    boot.loader.systemd-boot.consoleMode = lib.mkDefault "max";
    boot.loader.systemd-boot.configurationLimit = lib.mkDefault 15;
  };
}
