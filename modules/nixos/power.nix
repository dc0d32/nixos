{ config, lib, pkgs, variables, ... }:
# System-level power/suspend behavior. Applies on laptops and desktops;
# laptop-specific bits no-op on desktops.
{
  # Handle lid/power/suspend via logind. The old top-level shortcuts
  # (lidSwitch, powerKey, etc.) and extraConfig were all migrated into
  # services.logind.settings.Login (structured INI) in current nixpkgs.
  #
  # Lid policy:
  #   * undocked, on battery   → suspend (closing the lid means "I'm done")
  #   * undocked, on AC        → suspend (same intent; saves power)
  #   * docked / external HDMI → ignore  (don't blank a clamshell setup
  #                                       driving an external monitor)
  # Logind treats *any* connected external display as "docked" for this
  # check, which is the behavior we want — no extra config needed.
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "suspend";
    HandleLidSwitchDocked = "ignore";
    HandlePowerKey = "suspend";
    HandlePowerKeyLongPress = "poweroff";
    HandleSuspendKey = "suspend";
    HandleHibernateKey = "ignore";
    # We let idled (kernel-input idle daemon) drive idle-suspend timing
    # rather than logind, so don't double up here.
    IdleAction = "ignore";
  };

  # Power management: tlp if laptop, otherwise auto-cpufreq is fine either way.
  # mkDefault so WSL / hosts can override without ceremony.
  services.thermald.enable = lib.mkDefault true;
  powerManagement.enable = lib.mkDefault true;

  # Firmware updates (safe default on laptops/desktops alike).
  services.fwupd.enable = lib.mkDefault true;
}
