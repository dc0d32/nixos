# Idle handling: lock → DPMS off → suspend pipeline driven by the
# `idled` user daemon (packages/idled/), plus a PipeWire→ScreenSaver
# inhibit bridge so background audio prevents idle.
#
# Pattern A: importing this module IS enabling it. Per-stage timeouts
# and `powerSaverPercent` are declared as HM module options (NOT
# flake-parts singletons) so multi-laptop hosts can each carry their
# own values without conflicts. Each HM config sets `idle = { … };`
# inside its own `configurations.homeManager.<id>.module` block.
#
# Why HM-side options (not flake-parts top-level): the idle daemon
# is a per-user service writing per-user config. With more than one
# laptop in the flake, a flake-parts singleton conflicts on the first
# field that differs across hosts. Same fix as battery.nix.
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
{
  flake.modules.homeManager.idle = { lib, pkgs, config, ... }:
    let
      cfg = config.idle;
      batteryEnabled = cfg.powerSaverPercent > 0;
      batteryToml = lib.optionalString batteryEnabled ''

        [battery]
        power_saver_percent = ${toString cfg.powerSaverPercent}
        hysteresis = 5
      '';
      # Absolute store paths for every command idled spawns. idled invokes
      # commands via `sh -c "<cmd>"` which performs PATH lookup; under
      # systemd-user with strict sandboxing, the executor's default PATH
      # is just /nix/store/<systemd>/bin, so PATH lookups for quickshell /
      # niri / systemctl all fail with ENOENT. Pinning absolute paths
      # makes the commands hermetic — the unit's PATH could be empty and
      # they'd still resolve. The unit also sets a sane PATH below as
      # belt-and-suspenders, but these strings are the authoritative
      # source of truth.
      lockCmd = "${pkgs.quickshell}/bin/quickshell ipc call lock lock";
      dpmsOffCmd = "${pkgs.niri}/bin/niri msg action power-off-monitors";
      dpmsOnCmd = "${pkgs.niri}/bin/niri msg action power-on-monitors";
      suspendCmd = "${pkgs.systemd}/bin/systemctl suspend";
      configToml = ''
        [general]
        tick_ms = 1000
        respect_idle_inhibitors = true
        # Lock the screen *before* the system suspends/hibernates so on resume
        # the user sees the lockscreen, not a desktop flash. idled holds a
        # logind delay-inhibitor and releases it after the lock command has
        # had a moment to render.
        lock_before_sleep = "${lockCmd}"
        lock_settle_ms = 300

        [[stages]]
        name = "lock"
        timeout = ${toString cfg.lockAfter}
        command = "${lockCmd}"

        [[stages]]
        name = "dpms"
        timeout = ${toString cfg.dpmsAfter}
        command = "${dpmsOffCmd}"
        resume_command = "${dpmsOnCmd}"

        [[stages]]
        name = "suspend"
        timeout = ${toString cfg.suspendAfter}
        command = "${suspendCmd}"
      '' + batteryToml;
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
        powerSaverPercent = lib.mkOption {
          type = lib.types.int;
          default = 0;
          description = ''
            Switch to power-profiles-daemon "power-saver" at this
            percent on battery; restored when going back above the
            threshold (with 5% hysteresis). 0 = disabled (no battery
            section emitted in idled config). Mirrors
            `battery.powerSaverPercent` on the NixOS side; declared
            here too so hosts that import the HM idle module without
            also wiring the NixOS battery module can still get the
            power-saver behavior (or omit it).
          '';
        };
      };

      config = {
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
            # idled spawns commands via `sh -c`. systemd-user's default
            # PATH for spawned children on NixOS is just /nix/store/<systemd>/bin,
            # so unqualified PATH lookups (quickshell, niri, systemctl)
            # all fail with ENOENT — observed in the wild as silent
            # idle-stage failures (the lock command never fires, suspend
            # never fires, machine stays awake all night). The configToml
            # above already pins absolute store paths for every command,
            # so this PATH is technically redundant — but kept as a
            # belt-and-suspenders against future config edits or hand-
            # invocation via `systemctl --user start idled.service` from
            # an admin shell. Standard NixOS user-session bin dirs.
            Environment = [
              "RUST_LOG=info"
              "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin:${pkgs.systemd}/bin:${pkgs.coreutils}/bin"
            ];
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
            # we try to call it, AND after easyeffects so the PipeWire node graph
            # has the DSP filter chain in place. The bridge walks the graph at
            # startup; if easyeffects' nodes are still appearing while the bridge
            # is enumerating, the PipeWire client connection has been observed
            # to die (silently, exit code 1) and Restart=on-failure then loops
            # respawning until the graph stabilizes — costs nothing at steady
            # state but spams the journal at every login. Ordering after
            # easyeffects collapses that race in the common case.
            #
            # Note: After= is one-directional ordering only, not a hard
            # requirement; if easyeffects isn't enabled on this host, the
            # bridge still starts (just without the ordering hint).
            After = [ "graphical-session.target" "idled.service" "easyeffects.service" ];
            PartOf = [ "graphical-session.target" ];
            Requires = [ "pipewire.service" ];
            # Belt-and-suspenders for the race above: cap retries at 5 in 60s
            # so a degenerate startup (e.g. easyeffects also failing, no audio
            # graph ever stabilizing) can't burn forever. After the cap, the
            # unit goes to "failed" and stays there, visible in the rebuild
            # output's "degraded session" warning rather than silently looping
            # at 12 restarts/minute.
            StartLimitBurst = 5;
            StartLimitIntervalSec = 60;
          };

          Service = {
            ExecStart = "${pkgs.wayland-pipewire-idle-inhibit}/bin/wayland-pipewire-idle-inhibit --idle-inhibitor d-bus --media-minimum-duration 5";
            Restart = "on-failure";
            # Bumped from 5s to 10s: the failure mode is a startup race against
            # the audio graph, so longer waits between attempts give the graph
            # more time to settle before we retry. Combined with StartLimitBurst
            # above this caps total recovery time at ~50s.
            RestartSec = 10;
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
    };
}
