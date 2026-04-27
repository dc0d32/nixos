{ config, lib, pkgs, variables, ... }:
let
  cfg = variables.desktop.wallpaper or { };
  enabled = cfg.enable or false;
  wallpaperDir = cfg.directory or "%h/.wallpaper";
  intervalMinutes = cfg.intervalMinutes or 30;

  fetchScript = pkgs.writeShellScript "wallpaper-fetch" ''
    set -euo pipefail
    dir="${wallpaperDir}"
    mkdir -p "$dir"

    # Query wallhaven: nature, SFW, random sort, at least 1920x1200
    api="https://wallhaven.cc/api/v1/search?q=nature,landscape&categories=100&purity=100&sorting=random&atleast=1920x1200&ratios=16x9,16x10"
    json=$(${pkgs.curl}/bin/curl -fsSL "$api")

    # Pick a random result from the page and extract its image URL
    img_url=$(echo "$json" | ${pkgs.python3}/bin/python3 -c "
    import json, sys, random
    d = json.load(sys.stdin)
    items = d.get('data', [])
    if not items: sys.exit(1)
    print(random.choice(items)['path'])
    ")

    ext="''${img_url##*.}"
    dest="$dir/$(date +%Y%m%d-%H%M%S).$ext"
    current="$dir/current.$ext"

    ${pkgs.curl}/bin/curl -fsSL -o "$dest" "$img_url"

    # Atomically update the current symlink (also keep a .jpg alias for lock screen)
    ln -sf "$dest" "$current"
    ln -sf "$dest" "$dir/current.jpg"

    # Apply to running awww instance
    ${pkgs.awww}/bin/awww img "$current" --transition-type fade --transition-duration 1 || true

    # Keep only the 10 most recent files (exclude symlinks)
    find "$dir" -maxdepth 1 -type f | sort | head -n -10 | xargs -r rm -f
  '';
in
lib.mkIf enabled {
  home.packages = [ pkgs.awww ];

  systemd.user.services.awww-daemon = {
    Unit = {
      Description = "awww wallpaper daemon";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.awww}/bin/awww-daemon";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Fetch a new wallpaper from Unsplash and apply it
  systemd.user.services.wallpaper-fetch = {
    Unit = {
      Description = "Fetch a random nature wallpaper from Wallhaven";
      After = [ "network-online.target" "awww-daemon.service" ];
      Wants = [ "network-online.target" "awww-daemon.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${fetchScript}";
    };
  };

  systemd.user.timers.wallpaper-fetch = {
    Unit.Description = "Refresh wallpaper from Wallhaven every ${toString intervalMinutes} minutes";
    Timer = {
      OnBootSec = "30s";
      OnUnitActiveSec = "${toString intervalMinutes}min";
      Unit = "wallpaper-fetch.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
