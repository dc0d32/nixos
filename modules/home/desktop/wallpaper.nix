{ config, lib, pkgs, variables, ... }:
let
  cfg = variables.desktop.wallpaper or { };
  enabled = cfg.enable or false;
  wallpaperDir = cfg.directory or "$HOME/wallpaper";
in
lib.mkIf enabled {
  home.packages = [ pkgs.awww ];

  systemd.user.services.awww-daemon = {
    Unit = {
      Description = "awww wallpaper daemon";
    };
    Service = {
      Type = "forking";
      ExecStart = "${pkgs.awww}/bin/awww-daemon";
      Restart = "on-failure";
    };
  };

  systemd.user.services.wallpaper-slideshow = {
    Unit = {
      Description = "Wallpaper slideshow - cycles a random image every ${toString (cfg.intervalMinutes or 30)} minutes";
      Requires = "awww-daemon.service";
      After = "awww-daemon.service";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.awww}/bin/awww img $(find ${wallpaperDir} -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) | shuf -n1 | tail -1)";
      RemainAfterExit = true;
    };
  };

  systemd.user.timers.wallpaper-slideshow = {
    Unit = {
      Description = "Timer for wallpaper slideshow";
    };
    Timer = {
      OnActiveSec = "1min";
      OnUnitActiveSec = "${toString (cfg.intervalMinutes or 30)}min";
      Unit = "wallpaper-slideshow.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}