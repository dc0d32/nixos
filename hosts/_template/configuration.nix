{ pkgs, variables, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./host-packages.nix
  ];

  networking.hostName = variables.hostname;
  time.timeZone = variables.timezone;
  i18n.defaultLocale = variables.locale;
  console.keyMap = variables.keymap;

  # Bootloader: sensible UEFI default; override per-host if BIOS
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Primary user. Password must be set manually on first boot (`passwd`).
  users.users.${variables.user} = {
    isNormalUser = true;
    description = variables.user;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
    shell = pkgs.zsh;
  };

  # Required so users.users.*.shell = pkgs.zsh works
  programs.zsh.enable = true;

  # Enable flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = variables.stateVersion;
}
