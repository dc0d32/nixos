{ pkgs, lib, variables, ... }:
let
  isWsl = variables.wsl.enable or false;
in
{
  imports = [
    ./host-packages.nix
  ];

  networking.hostName = variables.hostname;
  console.keyMap = variables.keymap;
  # time.timeZone / i18n.defaultLocale are set from variables in
  # modules/nixos/locale.nix — no need to repeat them here.

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
