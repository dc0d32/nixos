{ config, lib, pkgs, variables, ... }:
# System-level power/suspend behavior. Applies on laptops and desktops;
# laptop-specific bits no-op on desktops.
{
  # Handle lid/power/suspend via logind. The old top-level shortcuts
  # (lidSwitch, powerKey, etc.) and extraConfig were all migrated into
  # services.logind.settings.Login (structured INI) in current nixpkgs.
  services.logind.settings.Login = {
    HandleLidSwitch              = "suspend";
    HandleLidSwitchDocked        = "ignore";
    HandleLidSwitchExternalPower = "suspend";
    HandlePowerKey               = "suspend";   # short press -> suspend
    HandlePowerKeyLongPress      = "poweroff";
    HandleSuspendKey             = "suspend";
    HandleHibernateKey           = "hibernate";
    # Idle target wired from user-level swayidle (more flexible than
    # logind's IdleAction); keep logind idle disabled here.
    IdleAction                   = "ignore";
  };

  # Power management: tlp if laptop, otherwise auto-cpufreq is fine either way.
  # mkDefault so WSL / hosts can override without ceremony.
  services.thermald.enable = lib.mkDefault true;
  powerManagement.enable = lib.mkDefault true;

  # Firmware updates (safe default on laptops/desktops alike).
  services.fwupd.enable = lib.mkDefault true;
}
