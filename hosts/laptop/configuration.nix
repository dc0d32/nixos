{ pkgs, lib, variables, ... }:
let
  isWsl = variables.wsl.enable or false;
in
{
  imports = [
    ./hardware-configuration.nix
    ./host-packages.nix
  ];

  networking.hostName = variables.hostname;
  time.timeZone = variables.timezone;
  i18n.defaultLocale = variables.locale;
  console.keyMap = variables.keymap;

  # Bootloader: sensible UEFI default for bare-metal / VM installs.
  # Forced off inside WSL — nixos-wsl owns the boot path.
  boot.loader.systemd-boot.enable = lib.mkDefault (!isWsl);
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault (!isWsl);

  # Primary user. Inside WSL, nixos-wsl creates the default user itself,
  # so we skip the explicit user declaration there to avoid conflicting
  # definitions.
  users.users.${variables.user} = lib.mkIf (!isWsl) {
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
