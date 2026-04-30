{ config, lib, pkgs, variables, ... }:
let
  cfg = variables.idle or { enable = true; };
  lockAfter    = cfg.lockAfter    or 900;
  dpmsAfter    = cfg.dpmsAfter    or 1020;
  suspendAfter = cfg.suspendAfter or 1800;

  # Battery watcher config. Driven from variables.battery.* on the host.
  # Emitted as a [battery] TOML block only if the host opted in; absence
  # of the section disables the watcher in idled (see packages/idled/
  # src/power.rs). PPD is required at runtime — gated on the host already
  # enabling power-profiles-daemon (it is via modules/nixos/desktop/niri.nix).
  bat = variables.battery or { enable = false; };
  batteryEnabled = (bat.enable or false) && ((bat.powerSaverPercent or 0) > 0);
  batteryToml = lib.optionalString batteryEnabled ''

    [battery]
    power_saver_percent = ${toString bat.powerSaverPercent}
    hysteresis = 5
  '';

  # idled config: each stage fires at `timeout` seconds since last input.
  # On any input after a stage has fired, its `resume_command` (if set)
  # is run so DPMS can wake monitors immediately.
  #
  # Why idled and not stasis/swayidle/hypridle: every wayland-protocol idle
  # daemon depends on smithay's ext_idle_notifier_v1, which is broken on
  # niri (Smithay #1892, open as of 2026-04). Resumed events are never sent,
  # so the daemon thinks the user is permanently idle and locks while typing.
  # idled reads /dev/input/event* directly to dodge this entirely. See
  # packages/idled/src/main.rs and docs/sessions/2026-04-29-idle-lock-fix.md.
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
    timeout = ${toString lockAfter}
    command = "quickshell ipc call lock lock"

    [[stages]]
    name = "dpms"
    timeout = ${toString dpmsAfter}
    command = "niri msg action power-off-monitors"
    resume_command = "niri msg action power-on-monitors"

    [[stages]]
    name = "suspend"
    timeout = ${toString suspendAfter}
    command = "systemctl suspend"
  '' + batteryToml;
in
lib.mkIf (cfg.enable) {
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
}
