{ ... }: {
  imports = [
    ./desktop/niri.nix
    ./desktop/login-ly.nix
    ./audio/pipewire.nix
    ./fonts.nix
    ./locale.nix
    ./users.nix
    ./nix-settings.nix
    ./system-utils.nix
    ./wsl.nix
    ./biometrics.nix
    ./battery.nix
  ];
}
