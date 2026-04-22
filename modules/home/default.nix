{ lib, pkgs, ... }:
let
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
in
{
  imports = [
    ./shell/zsh.nix
    ./editor/neovim.nix
    ./terminal/alacritty.nix
    ./git.nix
    ./tmux.nix
    ./direnv.nix
  ] ++ lib.optionals isLinux [
    ./desktop/niri.nix
    ./desktop/waybar.nix
  ];

  programs.home-manager.enable = true;
}
