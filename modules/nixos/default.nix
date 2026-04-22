{ ... }: {
  imports = [
    ./desktop/niri.nix
    ./audio/pipewire.nix
    ./networking.nix
    ./fonts.nix
    ./locale.nix
    ./users.nix
    ./nix-settings.nix
  ];
}
