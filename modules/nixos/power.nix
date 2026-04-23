{ config, lib, pkgs, variables, ... }:
# System-level power/suspend behavior. Applies on laptops and desktops;
# laptop-specific bits no-op on desktops.
{
  # Handle lid/power/suspend via logind. nixpkgs moved extraConfig to
  # services.logind.settings.Login (structured INI) — use that.
  services.logind = {
    lidSwitch = "suspend";
    lidSwitchDocked = "ignore";
    lidSwitchExternalPower = "suspend";
    powerKey = "suspend";          # short press power button -> suspend
    powerKeyLongPress = "poweroff";
    suspendKey = "suspend";
    hibernateKey = "hibernate";
    # idle target wired from the user-level swayidle (more flexible than
    # logind's IdleAction), so keep logind idle disabled here.
    settings.Login = {
      HandleLidSwitch = "suspend";
      IdleAction = "ignore";
    };
  };

  # Power management: tlp if laptop, otherwise auto-cpufreq is fine either way.
  # mkDefault so WSL / hosts can override without ceremony.
  services.thermald.enable = lib.mkDefault true;
  powerManagement.enable = lib.mkDefault true;

  # Firmware updates (safe default on laptops/desktops alike).
  services.fwupd.enable = lib.mkDefault true;
}
