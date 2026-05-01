# Idle handling: lock → DPMS off → suspend pipeline driven by the
# `idled` user daemon (packages/idled/), plus a PipeWire→ScreenSaver
# inhibit bridge so background audio prevents idle.
#
# Pattern A: importing this module IS enabling it. Three top-level
# options carry the per-stage timeouts (publicly tweakable per-host);
# the battery-watcher TOML block is emitted only when
# `battery.powerSaverPercent > 0` (already published by
# flake-modules/battery.nix).
#
# Why idled (not stasis/swayidle/hypridle): every wayland-protocol idle
# daemon depends on smithay's ext_idle_notifier_v1, which is broken on
# niri (Smithay #1892, open as of 2026-04). Resumed events are never
# sent, so the daemon thinks the user is permanently idle and locks
# while typing. idled reads /dev/input/event* directly to dodge this
# entirely. See packages/idled/src/main.rs and
# docs/sessions/2026-04-29-idle-lock-fix.md.
#
# Retire when: niri grows working ext_idle_notifier_v1 support and the
# user is willing to swap idled for hypridle/swayidle.
{ lib, config, ... }:
let
  cfg = config.idle;
  bat = config.battery;
  batteryEnabled = (bat.powerSaverPercent or 0) > 0;
  batteryToml = lib.optionalString batteryEnabled ''

    [battery]
    power_saver_percent = ${toString bat.powerSaverPercent}
    hysteresis = 5
  '';
in
{
  options.idle = {
    lockAfter = lib.mkOption {
      type = lib.types.int;
      default = 900;
      description = "Seconds of inactivity before locking the screen.";
    };
    dpmsAfter = lib.mkOption {
      type = lib.types.int;
      default = 1020;
      description = "Seconds of inactivity before powering off monitors.";
    };
    suspendAfter = lib.mkOption {
      type = lib.types.int;
      default = 1800;
      description = "Seconds of inactivity before systemd suspend.";
    };
  };

  config.flake.modules.homeManager.idle = { pkgs, ... }:
    let
      configToml = ''
        [general]
        tick_ms = 1000
        respect_idle_inhibitors = true
        # Lock the screen *before* the system suspends/hibernates so on resume
        # the user sees the lockscreen, not a desktop flash. idled holds a
        # logind delay-inhibitor and releases it after the lock command has
        # had a moment to render.
        lock_before_sleep = "quickshell ipc call lock lock"
        lock_settle_ms = 300

        [[stages]]
        name = "lock"
        timeout = ${toString cfg.lockAfter}
        command = "quickshell ipc call lock lock"

        [[stages]]
        name = "dpms"
        timeout = ${toString cfg.dpmsAfter}
        command = "niri msg action power-off-monitors"
        resume_command = "niri msg action power-on-monitors"

        [[stages]]
        name = "suspend"
        timeout = ${toString cfg.suspendAfter}
        command = "systemctl suspend"
      '' + batteryToml;
    in
    {
      home.packages = with pkgs; [ brightnessctl idled wayland-pipewire-idle-inhibit ];

      xdg.configFile."idled/config.toml" = {
        force = true;
        text = configToml;
      };

      systemd.user.services.idled = {
        Unit = {
          Description = "Kernel-input idle daemon";
          # Start after the wayland session is up so quickshell ipc / niri msg
          # work the first time we fire. graphical-session.target is set up by
          # the niri user service and home-manager's session integration.
          After = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
        };

        Service = {
          ExecStart = "${pkgs.idled}/bin/idled";
          Restart = "on-failure";
          RestartSec = 3;
          # Bound resource use; idled is a tiny event loop.
          MemoryMax = "64M";
          # Hardening. /dev/input must remain readable, so we can't use
          # PrivateDevices=true (which would mask /dev/input).
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictNamespaces = true;
          LockPersonality = true;
          RestrictRealtime = true;
          SystemCallArchitectures = "native";
          Environment = "RUST_LOG=info";
        };

        Install = {
          WantedBy = [ "graphical-session.target" ];
        };
      };

      # PipeWire → ScreenSaver inhibit bridge.
      #
      # idled hosts an org.freedesktop.ScreenSaver D-Bus server (see
      # packages/idled/src/screensaver.rs). Chrome on fullscreen video calls
      # it directly, but background audio (Spotify, podcasts, mpv-without-
      # ScreenSaver-support) does not. wayland-pipewire-idle-inhibit watches
      # PipeWire output streams and calls our Inhibit while any stream has
      # been active for at least --media-minimum-duration seconds.
      #
      # `--idle-inhibitor d-bus` (instead of the default `wayland`) targets
      # ScreenSaver instead of asking the compositor to register a Wayland
      # idle-inhibit object — niri honors Wayland inhibits but doesn't
      # translate them to anything idled can see. ScreenSaver is the bridge
      # that closes that gap.
      #
      # 5s minimum duration matches the bridge default; long enough to ignore
      # blip notification sounds and short enough to catch songs.
      systemd.user.services.wayland-pipewire-idle-inhibit = {
        Unit = {
          Description = "PipeWire → ScreenSaver idle inhibitor bridge";
          # Order after idled so the ScreenSaver service is registered before
          # we try to call it. Soft dependency — bridge will retry if idled
          # isn't up yet, but ordering avoids spurious early errors.
          After = [ "graphical-session.target" "idled.service" ];
          PartOf = [ "graphical-session.target" ];
          Requires = [ "pipewire.service" ];
        };

        Service = {
          ExecStart = "${pkgs.wayland-pipewire-idle-inhibit}/bin/wayland-pipewire-idle-inhibit --idle-inhibitor d-bus --media-minimum-duration 5";
          Restart = "on-failure";
          RestartSec = 5;
          MemoryMax = "64M";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictNamespaces = true;
          LockPersonality = true;
          RestrictRealtime = true;
          SystemCallArchitectures = "native";
        };

        Install = {
          WantedBy = [ "graphical-session.target" ];
        };
      };
    };
}
