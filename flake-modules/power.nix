# System-level power / suspend behavior. Applies on laptops and
# desktops; laptop-specific bits no-op on desktops.
#
# Pattern A: hosts opt in by importing this module. WSL hosts simply
# don't import it. No options needed — the policy here is uniform
# across hosts that want it.
#
# Retire when: NixOS upstream's logind defaults match this lid/power
#   policy out of the box, OR power management moves to a host-specific
#   module because the uniform policy stops fitting every box.
{ ... }:
{
  flake.modules.nixos.power = { lib, ... }: {
    # Handle lid/power/suspend via logind. The old top-level shortcuts
    # (lidSwitch, powerKey, etc.) and extraConfig were all migrated
    # into services.logind.settings.Login (structured INI) in current
    # nixpkgs.
    #
    # Lid policy:
    #   * undocked, on battery   → suspend (closing the lid means "I'm done")
    #   * undocked, on AC        → suspend (same intent; saves power)
    #   * docked / external HDMI → ignore  (don't blank a clamshell setup
    #                                       driving an external monitor)
    # Logind treats *any* connected external display as "docked" for
    # this check, which is the behavior we want — no extra config
    # needed.
    services.logind.settings.Login = {
      HandleLidSwitch = lib.mkDefault "suspend";
      HandleLidSwitchExternalPower = lib.mkDefault "suspend";
      HandleLidSwitchDocked = lib.mkDefault "ignore";
      HandlePowerKey = lib.mkDefault "suspend";
      HandlePowerKeyLongPress = lib.mkDefault "poweroff";
      HandleSuspendKey = lib.mkDefault "suspend";
      HandleHibernateKey = lib.mkDefault "ignore";
      # We let swayidle (flake-modules/idle.nix) drive idle-suspend
      # timing rather than logind, so don't double up here.
      IdleAction = lib.mkDefault "ignore";
    };

    # CPU/AC-vs-battery power policy is NOT decided here: laptops import
    # flake-modules/power-profile-auto.nix (power-profiles-daemon driven by
    # the battery%/AC matrix); the m-pc desktop just rides the kernel's
    # default intel_pstate governor. This module only provides the two
    # universally-safe knobs: thermald (Intel thermal daemon) and the
    # generic powerManagement bringup. mkDefault so a host can override
    # without ceremony.
    services.thermald.enable = lib.mkDefault true;
    powerManagement.enable = lib.mkDefault true;

    # Firmware updates (safe default on laptops/desktops alike).
    services.fwupd.enable = lib.mkDefault true;
  };
}
