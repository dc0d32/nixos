# Battery management for laptops:
#   * Charge thresholds (kernel sysfs) — cap at chargeStopThreshold to
#     extend pack lifespan, resume charging once it falls to
#     chargeStartThreshold.
#   * Hibernate-on-critical via UPower (PercentageCritical +
#     CriticalAction). Requires a swap area >= RAM size, which is
#     provisioned as a dedicated swap GPT partition by the disko
#     factory (flake-modules/disko.nix, `swapSize` arg on
#     `diskoLayouts.bare-metal` / `diskoLayouts.vm`). The disko swap
#     content type sets `boot.resumeDevice` to
#     /dev/disk/by-partlabel/disk-main-swap automatically so
#     hibernate-resume "just works" — no resume_offset, no per-host
#     kernelParam pin.
#   * Automatic "power-saver on low battery" is handled NATIVELY by
#     power-profiles-daemon 0.30+ (the BatteryAware feature, on by
#     default and persisted in /var/lib/power-profiles-daemon — which
#     impermanence keeps). PPD is a system daemon, so the switch applies
#     to every user (kids included) regardless of who is logged in, via
#     a clean profile hold that auto-restores when the battery recovers.
#     It triggers at UPower's "low" level (PercentageLow, set below), so
#     there is nothing to hand-roll here. This replaced an earlier custom
#     watcher (in idled, then briefly a swayidle-side timer) — do NOT
#     reintroduce one; just tune PercentageLow if the trigger point needs
#     to move.
#
# Pattern A: hosts opt in by importing this module. Hosts without a
# battery (desktops, VMs) simply don't import it.
#
# Per-NixOS-config option scoping: `options.battery` is declared
# INSIDE the NixOS module body (not at the flake-parts top level) so
# each NixOS configuration gets its own option values. Declaring it
# at the flake-parts level would make it a global singleton.
#
# Retire when: no host in the repo runs on battery (all are docked
#   desktops, VMs, or servers), OR the kernel's charge-threshold sysfs
#   interface plus UPower hibernate hand-off become a NixOS-native
#   option that supersedes this module.
{
  flake.modules.nixos.battery = { lib, pkgs, config, ... }:
    let
      cfg = config.battery;
    in
    {
      options.battery = {
        chargeStopThreshold = lib.mkOption {
          type = lib.types.int;
          default = 80;
          description = ''
            Cap charge at this percentage to extend pack lifespan. Set to
            100 (and recharge to full) before flying or other long unplug.
          '';
        };
        chargeStartThreshold = lib.mkOption {
          type = lib.types.int;
          default = 75;
          description = "Resume charging once battery falls to this percent.";
        };
        criticalPercent = lib.mkOption {
          type = lib.types.int;
          default = 10;
          description = "UPower CriticalAction triggers at this percentage.";
        };
        criticalAction = lib.mkOption {
          type = lib.types.enum [ "HybridSleep" "Hibernate" "PowerOff" ];
          default = "Hibernate";
          description = ''
            UPower action when battery hits criticalPercent. Hibernate
            requires a swap area >= RAM (provision via the disko
            factory's `swapSize` arg). Falls back to PowerOff if
            hibernate fails.
          '';
        };
        batteries = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "BAT0" ];
          example = [ "BAT0" "BAT1" ];
          description = ''
            Names of `/sys/class/power_supply/<name>` entries that
            should receive charge-threshold writes. Single-battery
            ThinkPads (e.g. X1 Yoga) keep the default
            `[ "BAT0" ]`. Dual-battery ThinkPads (e.g. T480 with
            external swappable BAT0 + internal BAT1) set
            `[ "BAT0" "BAT1" ]`. The same thresholds
            (chargeStartThreshold / chargeStopThreshold) are
            applied to every entry. tmpfiles `w+` ignores ENOENT,
            so listing a battery the host doesn't have silently
            no-ops, but be explicit so the intent is documented.
          '';
        };
      };

      config = {
        # ── Charge thresholds via sysfs ──────────────────────────────
        # The Lenovo X1 Yoga (and most ThinkPads on a recent kernel)
        # exposes:
        #   /sys/class/power_supply/BAT0/charge_control_start_threshold
        #   /sys/class/power_supply/BAT0/charge_control_end_threshold
        # plus the legacy charge_{start,stop}_threshold aliases. We write
        # both via systemd-tmpfiles so the values survive reboots without
        # depending on TLP (TLP and power-profiles-daemon cannot coexist;
        # we use PPD).
        #
        # Order matters on some kernels: writing end_threshold below the
        # current start_threshold can fail. Write start first (lowering
        # it is safe), then end. tmpfiles `w+` overwrites, ignores ENOENT
        # (so non-Lenovo hardware without these files just no-ops).
        #
        # Multi-battery hosts (e.g. T480 with BAT0 external + BAT1
        # internal) declare every battery name in `battery.batteries`;
        # the same thresholds get applied to each.
        systemd.tmpfiles.rules = lib.concatMap
          (bat: [
            "w+ /sys/class/power_supply/${bat}/charge_control_start_threshold - - - - ${toString cfg.chargeStartThreshold}"
            "w+ /sys/class/power_supply/${bat}/charge_control_end_threshold   - - - - ${toString cfg.chargeStopThreshold}"
          ])
          cfg.batteries;

        # ── UPower critical action ───────────────────────────────────
        # UPower's daemon (services.upower.enable, set in flake-modules/
        # niri.nix once that migrates) reads /etc/UPower/UPower.conf for
        # action thresholds. The default is to do nothing on critical;
        # we override to hibernate.
        #
        # Documented options:
        #   PercentageLow / PercentageCritical / PercentageAction
        #   CriticalPowerAction = HybridSleep | Hibernate | PowerOff
        # We set Critical to the user's threshold and Action one step
        # below so there's a chance to react before hibernate kicks in.
        environment.etc."UPower/UPower.conf".text = ''
          [UPower]
          EnableWattsBackend=true
          NoPollBatteries=false
          UsePercentageForPolicy=true
          PercentageLow=20
          PercentageCritical=${toString (cfg.criticalPercent + 5)}
          PercentageAction=${toString cfg.criticalPercent}
          TimeLow=1200
          TimeCritical=300
          TimeAction=120
          CriticalPowerAction=${cfg.criticalAction}
        '';
      };
    };
}
