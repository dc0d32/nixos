{ lib, variables ? { }, ... }:
# Intentionally does NOT take `pkgs` as a module argument. Reading `pkgs` in a
# module that computes `imports` creates an infinite recursion under
# home-manager: imports are resolved before config, but `pkgs` here is not a
# specialArg — it resolves through `_module.args`, which requires `config`,
# which hasn't been evaluated yet.
#
# We use `variables.system` (a specialArg, no config needed) to decide which
# imports apply.
let
  system = variables.system or "x86_64-linux";
  isLinux = lib.hasSuffix "linux" system;
  isWsl = variables.wsl.enable or false;
  hasDesktop = isLinux && !isWsl;
in
{
  imports = [
    ./shell/zsh.nix
    ./editor/neovim.nix
    ./editor/vscode.nix
    ./terminal/alacritty.nix
  ] ++ lib.optionals hasDesktop [
    ./audio/easyeffects.nix
    ./desktop/extras.nix
    ./desktop/niri.nix
    ./desktop/polkit-agent.nix
    ./desktop/waybar.nix
    ./desktop/quickshell
    ./desktop/idle.nix
    ./desktop/wallpaper.nix
    ./apps/chrome.nix
    ./apps/bitwarden.nix
    ./cad/freecad.nix
  ];

  programs.home-manager.enable = true;
}
