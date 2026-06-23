# Nix daemon settings for home-manager — currently just a two-stage GC
# (age + count floor) for the user profile and the home-manager profile.
# The system-side equivalent is flake-modules/nix-settings.nix.
#
# Pattern A: HM bundles opt in by including this module. Universally
# imported via flake-modules/bundles/home-base.nix so every account in
# the flake gets the same GC policy by default.
#
# Why a separate module from nix-settings.nix: NixOS-side nix.gc and
# HM-side nix.gc are different option sets — the former runs as the
# nix-daemon (system profile only), the latter runs as the user (user
# profile and ~/.local/state/nix/profiles/home-manager). Both are
# needed to keep total disk/profile pressure bounded; neither prunes
# the other's generations.
#
# Why a custom timer instead of nix.gc.{automatic,dates,options}: same
# reason as the system side — we want both "older than 14d" and "keep
# at least the last 15" together, and nix-collect-garbage doesn't take
# both flags at once. See flake-modules/nix-settings.nix for the full
# rationale; this module mirrors that policy on the user side.
#
# What gets pruned by each stage:
#   1. nix-collect-garbage --delete-older-than 14d
#      → user-owned profiles: the user profile (rare; only used if you
#      `nix-env -i` something) and ~/.local/state/nix/profiles/home-manager
#      (every HM activation creates a new generation here).
#   2. nix-env --profile ~/.local/state/nix/profiles/home-manager
#                 --delete-generations +15
#      → trims to 15 newest HM generations if step 1 left more.
#      Rollback target via `home-manager generations`.
#
# Retire when: HM upstream defaults converge on a count-floor GC, OR
#   the flake collapses to a single account (then merging this back into
#   nix-settings.nix as a cross-class module makes more sense).
{ ... }:
let
  # Two-stage GC, shared by the Linux (systemd-user) and Darwin
  # (launchd-agent) schedulers below so the policy never drifts. Stage 1
  # sweeps all user-owned profiles by age, stage 2 enforces a
  # 15-generation floor on the HM profile. Path to the HM profile is the
  # standard XDG_STATE_HOME location used by home-manager since release
  # 22.11; $HOME is expanded at runtime, not Nix-eval time, so the same
  # script works for any user who imports this module.
  gcScript = pkgs: pkgs.writeShellScript "nix-gc-twostage-user" ''
    set -eu
    echo "Stage 1: nix-collect-garbage --delete-older-than 14d"
    ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 14d
    echo "Stage 2: keep last 15 HM generations"
    ${pkgs.nix}/bin/nix-env \
      --profile "$HOME/.local/state/nix/profiles/home-manager" \
      --delete-generations +15
  '';
in
{
  flake.modules.homeManager.nix-settings = { pkgs, lib, ... }:
    lib.mkMerge [
      # ── Linux: systemd-user timer ────────────────────────────────
      (lib.mkIf pkgs.stdenv.isLinux {
        systemd.user.services.nix-gc-twostage = {
          Unit = {
            Description = "Two-stage Nix GC (user): --delete-older-than 14d, then keep 15 newest HM generations";
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${gcScript pkgs}";
          };
        };
        systemd.user.timers.nix-gc-twostage = {
          Unit = {
            Description = "Weekly two-stage Nix GC (user)";
          };
          Timer = {
            OnCalendar = "weekly";
            Persistent = true;
            RandomizedDelaySec = "1h";
          };
          Install = {
            WantedBy = [ "timers.target" ];
          };
        };
      })

      # ── Darwin: launchd user agent ───────────────────────────────
      # launchd has no systemd-timer equivalent of Persistent= /
      # RandomizedDelaySec=; StartCalendarInterval fires at a fixed
      # wall-clock time and, like a Persistent= timer, catches up at
      # the next opportunity if the Mac was asleep at the scheduled
      # moment. Sunday 03:15 local mirrors the Linux "weekly" cadence.
      (lib.mkIf pkgs.stdenv.isDarwin {
        launchd.agents.nix-gc-twostage = {
          enable = true;
          config = {
            ProgramArguments = [ "${gcScript pkgs}" ];
            StartCalendarInterval = [
              { Weekday = 0; Hour = 3; Minute = 15; }
            ];
          };
        };
      })
    ];
}
