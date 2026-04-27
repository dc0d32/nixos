{ config, lib, pkgs, variables, ... }:
# System-level power/suspend behavior. Applies on laptops and desktops;
# laptop-specific bits no-op on desktops.
{
  # Handle lid/power/suspend via logind. The old top-level shortcuts
  # (lidSwitch, powerKey, etc.) and extraConfig were all migrated into
  # services.logind.settings.Login (structured INI) in current nixpkgs.
  services.logind.settings.Login = {
    # Let logind handle power button
    HandleLidSwitch = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandlePowerKey = "suspend";
    HandlePowerKeyLongPress = "poweroff";
    HandleSuspendKey = "suspend";
    HandleHibernateKey = "ignore";
    IdleAction = "ignore";
  };

  # Power management: tlp if laptop, otherwise auto-cpufreq is fine either way.
  # mkDefault so WSL / hosts can override without ceremony.
  services.thermald.enable = lib.mkDefault true;
  powerManagement.enable = lib.mkDefault true;

  # Firmware updates (safe default on laptops/desktops alike).
  services.fwupd.enable = lib.mkDefault true;
}
