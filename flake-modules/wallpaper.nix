# Wallpaper rotation: awww daemon + a systemd timer that pulls a fresh
# nature/landscape image from Wallhaven every `intervalMinutes`.
#
# Migrated from modules/home/desktop/wallpaper.nix. Pattern A: importing
# this module IS enabling it (legacy `desktop.wallpaper.enable` gate
# dropped). The poll interval and storage directory remain configurable
# via top-level `wallpaper.*` options.
#
# Retire when: wallpaper provider changes (e.g. local image rotation,
# different API), or awww is replaced by a different wallpaper agent.
{ lib, config, ... }:
let
  cfg = config.wallpaper;
in
{
  options.wallpaper = {
    intervalMinutes = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = ''
        How often to fetch a new wallpaper from Wallhaven, in minutes.
      '';
    };
    directory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "\${HOME}/.wallpaper";
      description = ''
        Directory to store fetched wallpapers in. When null (default),
        uses `\${config.home.homeDirectory}/.wallpaper` so the path is
        always correct for the user being built.
      '';
    };
  };

  config.flake.modules.homeManager.wallpaper = { config, pkgs, ... }:
    let
      wallpaperDir =
        if cfg.directory != null
        then cfg.directory
        else "${config.home.homeDirectory}/.wallpaper";

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
    {
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

      # Fetch a new wallpaper from Wallhaven and apply it
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
        Unit.Description = "Refresh wallpaper from Wallhaven every ${toString cfg.intervalMinutes} minutes";
        Timer = {
          OnBootSec = "30s";
          OnUnitActiveSec = "${toString cfg.intervalMinutes}min";
          Unit = "wallpaper-fetch.service";
        };
        Install.WantedBy = [ "timers.target" ];
      };
    };
}
