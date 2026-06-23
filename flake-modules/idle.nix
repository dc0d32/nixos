# Idle handling: lock → DPMS off → suspend pipeline driven by the
# standard `swayidle` daemon, plus a PipeWire→idle-inhibit bridge so
# background audio prevents idle.
#
# Pattern A: importing this module IS enabling it. Per-stage timeouts
# are declared as HM module options (NOT flake-parts singletons) so
# multi-laptop hosts can each carry their own values without conflicts.
# Each HM config sets `idle = { … };` inside its own
# `configurations.homeManager.<id>.module` block.
#
# Battery → power-saver auto-switching is NOT here: power-profiles-daemon
# 0.30+ does it natively (the BatteryAware feature, on by default), and
# being a system daemon it applies to every user — see flake-modules/
# battery.nix.
#
# Why HM-side options (not flake-parts top-level): the idle daemon
# is a per-user service writing per-user config. With more than one
# laptop in the flake, a flake-parts singleton conflicts on the first
# field that differs across hosts. Same fix as battery.nix.
#
# Why swayidle now (was: a bespoke `idled` Rust daemon): idled existed
# only because niri's Smithay-based ext-idle-notify-v1 didn't deliver
# *resumed* events (the daemon thought the user was permanently idle and
# locked while typing — Smithay #1892). The pinned niri now implements
# IdleNotifierHandler + delegate_idle_notify! and calls notify_activity()
# on input (src/input/mod.rs), which fires the resumed event, so
# swayidle works correctly. Retiring idled also fixed a lockscreen bug:
# idled ran with systemd NoNewPrivileges=true, which neutered the setuid
# unix_chkpwd helper for any locker it spawned, so pam_unix could not
# read /etc/shadow and rejected the password. swayidle (this module's HM
# service) carries no such sandbox, so swaylock authenticates normally.
# See docs/sessions/2026-06-22-retire-idled-swayidle.md.
#
# Retire when: niri ships a first-party lock/idle stack, or you move to a
#   different compositor whose idle story differs.
{
  flake.modules.homeManager.idle = { lib, pkgs, config, ... }:
    let
      cfg = config.idle;

      # Single-instance lock wrapper. swaylock's config carries
      # `daemonize` (fork-and-return), so a stale instance leaves a pid;
      # guard against the "another lockscreen is already running" noise
      # that double-fires (idle lock + before-sleep, or a manual lock on
      # top of an idle lock) would otherwise produce.
      lockScreen = pkgs.writeShellScript "lock-screen" ''
        ${pkgs.procps}/bin/pidof -x swaylock >/dev/null 2>&1 && exit 0
        exec ${pkgs.swaylock-effects}/bin/swaylock
      '';
      dpmsOffCmd = "${pkgs.niri}/bin/niri msg action power-off-monitors";
      dpmsOnCmd = "${pkgs.niri}/bin/niri msg action power-on-monitors";
      suspendCmd = "${pkgs.systemd}/bin/systemctl suspend";
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

      config = {
        home.packages = with pkgs; [ brightnessctl wayland-pipewire-idle-inhibit ];

        # ── swayidle: staged lock → dpms → suspend ──────────────────
        # niri delivers ext-idle-notify-v1 resumed events on input, so
        # swayidle's timeouts/resume work natively. before-sleep locks
        # ahead of suspend (swayidle holds a logind delay-inhibitor) so
        # on resume the user sees the lockscreen, not a desktop flash.
        # `lock` mirrors before-sleep so `loginctl lock-session` (bound
        # to Super+Alt+L in niri.nix) routes through a single handler.
        services.swayidle = {
          enable = true;
          timeouts = [
            { timeout = cfg.lockAfter; command = "${lockScreen}"; }
            {
              timeout = cfg.dpmsAfter;
              command = dpmsOffCmd;
              resumeCommand = dpmsOnCmd;
            }
            { timeout = cfg.suspendAfter; command = suspendCmd; }
          ];
          events = {
            before-sleep = "${lockScreen}";
            lock = "${lockScreen}";
          };
        };

        # PipeWire → idle-inhibit bridge.
        #
        # wayland-pipewire-idle-inhibit watches PipeWire output streams
        # and asserts a Wayland idle-inhibitor (zwp_idle_inhibit) while
        # any stream has been active for at least --media-minimum-duration
        # seconds. niri implements IdleInhibitHandler, so an active
        # inhibitor stops niri emitting idle → swayidle never fires.
        # Background audio (Spotify, podcasts, mpv) thus prevents the
        # screen locking even though those apps don't call the
        # org.freedesktop.ScreenSaver D-Bus API themselves. Chrome's
        # fullscreen video already speaks the Wayland idle-inhibit
        # protocol directly, so it is covered too.
        #
        # `--idle-inhibitor wayland` (the default) replaces idled's
        # bespoke org.freedesktop.ScreenSaver server, which only existed
        # because idled couldn't see Wayland inhibits. With a standard
        # compositor + idle daemon, the Wayland protocol is the bridge.
        #
        # 5s minimum duration: long enough to ignore notification blips,
        # short enough to catch songs.
        systemd.user.services.wayland-pipewire-idle-inhibit = {
          Unit = {
            Description = "PipeWire → Wayland idle-inhibit bridge";
            # `--idle-inhibitor wayland` needs WAYLAND_DISPLAY in the
            # unit env. Gate on it (same pattern as HM's swayidle unit):
            # if the compositor env isn't imported yet the unit is
            # cleanly skipped rather than failing fast 6× and tripping
            # the start-limit into a stranded `failed` state — observed
            # on the d-bus→wayland switch. graphical-session ordering
            # provides the env on a normal boot.
            ConditionEnvironment = "WAYLAND_DISPLAY";
            # Order after easyeffects so the PipeWire node graph has the
            # DSP filter chain in place before the bridge enumerates it;
            # enumerating mid-construction has been observed to kill the
            # PipeWire client connection (silent exit 1), which then
            # Restart=on-failure-loops until the graph stabilizes —
            # cheap at steady state but journal spam at every login.
            After = [ "graphical-session.target" "easyeffects.service" ];
            PartOf = [ "graphical-session.target" ];
            Requires = [ "pipewire.service" ];
            StartLimitBurst = 5;
            StartLimitIntervalSec = 60;
          };

          Service = {
            ExecStart = "${pkgs.wayland-pipewire-idle-inhibit}/bin/wayland-pipewire-idle-inhibit --idle-inhibitor wayland --media-minimum-duration 5";
            Restart = "on-failure";
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
