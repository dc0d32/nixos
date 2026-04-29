{ config, lib, pkgs, variables, ... }:
let
  cfg = variables.idle or { enable = true; };
  lockAfter    = cfg.lockAfter    or 900;
  dpmsAfter    = cfg.dpmsAfter    or 1020;
  suspendAfter = cfg.suspendAfter or 1800;

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
  '';
in
lib.mkIf (cfg.enable) {
  home.packages = with pkgs; [ brightnessctl idled ];

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
}
