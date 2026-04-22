{ inputs, lib, pkgs, variables, ... }:
let cfg = variables.desktop.niri or { enable = false; };
in
lib.mkIf (cfg.enable or false) {
  # Pull in niri-flake's HM module if available
  imports = lib.optional (inputs ? niri) inputs.niri.homeModules.niri;

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
}
