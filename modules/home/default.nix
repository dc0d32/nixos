{ lib, pkgs, variables ? { }, ... }:
let
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  isWsl   = variables.wsl.enable or false;
  hasDesktop = isLinux && !isWsl;
in
{
  imports = [
    ./shell/zsh.nix
    ./editor/neovim.nix
    ./terminal/alacritty.nix
    ./tools/btop.nix
    ./tools/build-deps.nix
    ./git.nix
    ./tmux.nix
    ./direnv.nix
  ] ++ lib.optionals hasDesktop [
    ./desktop/niri.nix
    ./desktop/waybar.nix
    ./desktop/quickshell
    ./desktop/idle.nix
    ./apps/chrome.nix
  ];

  programs.home-manager.enable = true;
}
