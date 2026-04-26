{ config, lib, pkgs, variables, ... }:
# User-level idle behavior under niri/wayland:
#   5 min  -> lock screen (swaylock)
#   7 min  -> turn displays off (niri msg action power-off-monitors)
#   15 min -> suspend
#
# Uses swayidle which is the standard wlroots idle daemon. Niri exposes
# power-off-monitors via `niri msg action` so we use that rather than
# wlopm/kanshi.
#
# Toggle via variables.idle.enable (default: true).
let
  cfg = variables.idle or { enable = true; };
  wpcfg = variables.desktop.wallpaper or { };
  wallpaperDir = wpcfg.directory or "$HOME/wallpaper";
in
lib.mkIf (cfg.enable or true) {
  home.packages = with pkgs; [ swayidle swaylock brightnessctl ];

  services.swayidle = {
    enable = true;
    systemdTargets = [ "graphical-session.target" ];
    events = {
      "before-sleep" = "${pkgs.swaylock}/bin/swaylock -f -i $(find ${wallpaperDir} -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) | shuf -n1 | tail -1)";
      "lock" = "${pkgs.swaylock}/bin/swaylock -f -i $(find ${wallpaperDir} -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) | shuf -n1 | tail -1)";
    };
    timeouts = [
      { timeout = (cfg.lockAfter    or 300); command = "${pkgs.swaylock}/bin/swaylock -f -i $(find ${wallpaperDir} -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) | shuf -n1 | tail -1)"; }
      {
        timeout = (cfg.dpmsAfter    or 420);
        command = "niri msg action power-off-monitors";
        resumeCommand = "niri msg action power-on-monitors";
      }
      { timeout = (cfg.suspendAfter or 900); command = "systemctl suspend"; }
    ];
  };
}
