{ inputs, lib, pkgs, variables, ... }:
let
  cfg = variables.desktop.niri or { enable = false; };
  enabled = cfg.enable or false;
in
{
  imports = lib.optional (enabled && (inputs ? niri)) inputs.niri.homeModules.niri;

  config = lib.mkIf enabled {
    programs.niri.settings = {
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
      binds = {
        "Mod+Return".action.spawn = "alacritty";
        "Mod+D".action.spawn = "fuzzel";
        "Mod+Q".action.close-window = {};
        "Mod+Shift+E".action.quit = {};
        "Mod+H".action.focus-column-left = {};
        "Mod+L".action.focus-column-right = {};
        "Mod+J".action.focus-window-down = {};
        "Mod+K".action.focus-window-up = {};

        "XF86AudioRaiseVolume".action.spawn = ["wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%+"];
        "XF86AudioLowerVolume".action.spawn = ["wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"];
        "XF86AudioMute".action.spawn = ["wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"];

        "XF86MonBrightnessUp".action.spawn = ["brightnessctl" "set" "+5%"];
        "XF86MonBrightnessDown".action.spawn = ["brightnessctl" "set" "5%-"];

        "XF86AudioPlay".action.spawn = "playerctl play-pause";
        "XF86AudioNext".action.spawn = "playerctl next";
        "XF86AudioPrev".action.spawn = "playerctl previous";
      };
    };
  };
}