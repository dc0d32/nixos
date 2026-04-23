{ inputs, lib, pkgs, variables, ... }:
# `imports` is resolved before config evaluation, so it cannot live inside
# lib.mkIf. Split: top-level imports gated via lib.optional on enable +
# flake presence, and the config block under lib.mkIf.
let
  cfg = variables.desktop.niri or { enable = false; };
  enabled = cfg.enable or false;
in
{
  imports = lib.optional (enabled && (inputs ? niri)) inputs.niri.homeModules.niri;

  config = lib.mkIf enabled {
    programs.niri.settings = {
      # Minimal sane defaults; edit to taste
      input.keyboard.xkb.layout = "us";
      input.touchpad = {
        tap = true;
        natural-scroll = true;
      };
      prefer-no-csd = true;
      layout = {
        gaps = 8;
        border.width = 2;
      };
      binds = with lib; {
        "Mod+Return".action.spawn = "alacritty";
        "Mod+D".action.spawn = "fuzzel";
        "Mod+Q".action.close-window = { };
        "Mod+Shift+E".action.quit = { };
        "Mod+H".action.focus-column-left = { };
        "Mod+L".action.focus-column-right = { };
        "Mod+J".action.focus-window-down = { };
        "Mod+K".action.focus-window-up = { };
      };
    };
  };
}
