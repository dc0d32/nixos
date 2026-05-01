# Wallpaper rotation: awww daemon + a systemd timer that pulls a fresh
# nature/landscape image from Wallhaven every `intervalMinutes`.
#
# Pattern A: importing this module IS enabling it. The poll interval
# and storage directory are configurable via top-level `wallpaper.*`
# options.
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

        # Wait for awww-daemon's IPC socket to appear before doing
        # anything network. The systemd Wants/After on awww-daemon
        # only guarantees ORDER, not READINESS — a Type=simple unit is
        # "started" the instant exec returns, well before awww-daemon
        # has finished negotiating with the Wayland compositor and
        # bound its socket. If we proceed too early, `awww img` fails
        # with "Socket file '…wayland-1-awww-daemon.sock' not found"
        # and the whole timer instance is wasted (we'd download an
        # image just to throw it away). Poll up to 30s.
        sock="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY-awww-daemon.sock"
        for _ in $(seq 1 30); do
          [ -S "$sock" ] && break
          sleep 1
        done
        if [ ! -S "$sock" ]; then
          echo "wallpaper-fetch: awww-daemon socket $sock did not appear within 30s; bailing" >&2
          exit 0
        fi

        # Query wallhaven: nature, SFW, random sort, at least 1920x1200
        api="https://wallhaven.cc/api/v1/search?q=nature,landscape&categories=100&purity=100&sorting=random&atleast=1920x1200&ratios=16x9,16x10"
        json=$(${pkgs.curl}/bin/curl -fsSL "$api")

        # Pick a random result from the page and extract its image URL.
        # NOTE: the python heredoc body MUST sit at the same column as
        # the surrounding shell statements. Nix's indented-string
        # strip removes the minimum common leading whitespace; if these
        # python lines drift even one column further in, Python sees
        # leading spaces and dies with IndentationError. Don't reformat.
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
          # If the env-import in niri's spawn-at-startup is still
          # racing graphical-session.target activation, awww-daemon
          # may start with no WAYLAND_DISPLAY and crash with a
          # libwayland-client connect failure. Allow up to 10
          # restarts in 60s (each spaced 2s apart by RestartSec
          # below) so the daemon rides out the env-propagation race
          # rather than tripping systemd's start-limit.
          StartLimitBurst = 10;
          StartLimitIntervalSec = 60;
        };
        Service = {
          Type = "simple";
          ExecStart = "${pkgs.awww}/bin/awww-daemon";
          Restart = "on-failure";
          # Default RestartSec is 100ms; with 5 default StartLimitBurst,
          # systemd gives up in <1s — well before niri's
          # spawn-at-startup chain has a chance to finish. 2s gives
          # the env-import dbus call enough headroom while still
          # being snappy enough that the user doesn't see a long
          # gray-screen window on a normal boot.
          RestartSec = 2;
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
