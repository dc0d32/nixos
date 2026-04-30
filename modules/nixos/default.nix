{ ... }: {
  imports = [
    ./desktop/niri.nix
    ./desktop/login-ly.nix
    ./audio/pipewire.nix
    ./locale.nix
    ./wsl.nix
    ./biometrics.nix
    ./battery.nix
  ];
}
