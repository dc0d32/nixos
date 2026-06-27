# Battery-aware power-profile auto-switching for laptops.
#
# Implements this exact policy (per-host, system-wide via PPD):
#
#                    │  on AC (external power)  │  on battery
#   ─────────────────┼──────────────────────────┼──────────────
#   battery ≥ 20%    │  performance             │  balanced
#   battery < 20%    │  power-saver  ← (AC) but │  power-saver
#                    │  balanced     ← see note │
#
#   i.e.  AC  & ≥20% → performance
#         AC  & <20% → balanced
#         BAT & ≥20% → balanced
#         BAT & <20% → power-saver
#
# Why this module exists
# ----------------------
# No maintained power tool does *percentage-based* profile switching:
# power-profiles-daemon, tuned-ppd, TLP and auto-cpufreq all switch only
# on AC-vs-battery (two states). The requirement above is a four-state
# matrix gated on a 20% threshold, which maps cleanly onto PPD's three
# named profiles — so we keep PPD (it applies each profile's intel_pstate
# EPP/boost correctly and gives `powerprofilesctl` for manual override)
# and add a tiny watcher that drives it from the (on-battery, <20%) matrix.
#
# This supersedes the brief TLP experiment: TLP could only express the
# AC/battery axis, not the 20% tier. PPD's old "latch" footgun (a stale
# persisted profile capping the CPU) cannot recur here — the watcher
# re-asserts the correct profile on every power event and every 60 s, and
# PPD's state dir is deliberately not persisted (flake-modules/
# impermanence.nix).
#
# Charge limiting to 80% is unrelated to this module — it's owned by
# flake-modules/battery.nix (chargeStopThreshold, set to 80 on both
# laptops via kernel sysfs).
#
# Pattern A: imported by the LAPTOP bridges only (pb-x1, pb-t480). The
# m-pc desktop has no battery and stays on the kernel governor.
#
# Retire when: power-profiles-daemon (or a maintained successor) grows
#   native battery-percentage profile rules, OR the flake drops laptops.
{
  flake.modules.nixos.power-profile-auto = { lib, pkgs, ... }:
    let
      ppAuto = pkgs.writeShellApplication {
        name = "power-profile-auto";
        runtimeInputs = [ pkgs.systemd pkgs.power-profiles-daemon pkgs.gawk ];
        text = ''
          # External power vs battery, via UPower's aggregate — handles
          # USB-C PD, docks, and the T480's dual battery (the DisplayDevice
          # aggregates BAT0+BAT1 into one percentage).
          on_battery=$(busctl get-property org.freedesktop.UPower \
            /org/freedesktop/UPower org.freedesktop.UPower OnBattery \
            2>/dev/null | awk '{print $2}')
          pct=$(busctl get-property org.freedesktop.UPower \
            /org/freedesktop/UPower/devices/DisplayDevice \
            org.freedesktop.UPower.Device Percentage 2>/dev/null | awk '{print $2}')

          # Bail quietly if UPower isn't ready yet (don't flap to a wrong
          # default during early boot).
          if [ -z "$on_battery" ] || [ -z "$pct" ]; then
            exit 0
          fi

          # Integer percent; bail if it isn't a clean number.
          pct=''${pct%.*}
          case "$pct" in
            "" | *[!0-9]*) exit 0 ;;
          esac

          low=0
          if [ "$pct" -lt 20 ]; then low=1; fi

          if [ "$on_battery" = "false" ]; then
            # On external power.
            if [ "$low" -eq 1 ]; then target=balanced; else target=performance; fi
          else
            # On battery.
            if [ "$low" -eq 1 ]; then target=power-saver; else target=balanced; fi
          fi

          current=$(powerprofilesctl get 2>/dev/null || true)
          if [ "$current" != "$target" ]; then
            powerprofilesctl set "$target"
            echo "power-profile-auto: on_battery=$on_battery pct=$pct% -> $target (was ''${current:-unknown})"
          fi
        '';
      };
    in
    {
      # PPD provides the three named profiles and applies each correctly to
      # intel_pstate. Enabled here (importing IS enabling) so it lands only
      # on hosts that want battery-aware switching.
      services.power-profiles-daemon.enable = true;

      # The watcher runs as a root system service, which has no *active*
      # login session — and PPD's switch-profile polkit action only allows
      # active sessions (allow_any/allow_inactive = no). Grant root the two
      # profile actions so the watcher can switch non-interactively.
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if ((action.id == "org.freedesktop.UPower.PowerProfiles.switch-profile" ||
               action.id == "org.freedesktop.UPower.PowerProfiles.hold-profile") &&
              subject.user == "root") {
            return polkit.Result.YES;
          }
        });
      '';

      systemd.services.power-profile-auto = {
        description = "Apply power-profile from the battery%/AC matrix";
        after = [ "power-profiles-daemon.service" "upower.service" ];
        wants = [ "power-profiles-daemon.service" "upower.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe ppAuto;
        };
      };

      # Periodic re-evaluation catches the 20% crossing while discharging
      # (there is no power_supply uevent for a gradual percentage change).
      # OnUnitActiveSec is relative to the last run, so udev-triggered runs
      # reset it — at most ~60 s of lag, usually instant.
      systemd.timers.power-profile-auto = {
        description = "Re-evaluate the power-profile matrix periodically";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30s";
          OnUnitActiveSec = "60s";
        };
      };

      # Instant re-evaluation on AC plug/unplug (any power_supply change).
      # NOTE: udev comments must sit on their own line — a trailing inline
      # comment after rule tokens fails `udevadm verify` / the build.
      services.udev.extraRules = ''
        ACTION=="change", SUBSYSTEM=="power_supply", RUN+="${pkgs.systemd}/bin/systemctl --no-block start power-profile-auto.service"
      '';
    };
}
