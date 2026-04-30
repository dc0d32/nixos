{ ... }: {
  imports = [
    ./desktop/niri.nix
    ./desktop/login-ly.nix
    ./wsl.nix
    ./biometrics.nix
  ];
}
