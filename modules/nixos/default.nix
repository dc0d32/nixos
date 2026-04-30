{ ... }: {
  imports = [
    ./desktop/niri.nix
    ./desktop/login-ly.nix
    ./audio/pipewire.nix
    ./wsl.nix
    ./biometrics.nix
    ./battery.nix
  ];
}
