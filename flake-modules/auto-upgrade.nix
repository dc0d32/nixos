# auto-upgrade — the system half of auto-deploy: rebuild this host's
# NixOS closure from `origin/main` on GitHub.
#
# It contributes ONE unit, `nixos-auto-upgrade.service`, and no timer.
# Scheduling, the wall-power gate, the reachability gate and the
# ordering against home-manager all live in the driver,
# flake-modules/auto-update.nix — this module only knows *how* to
# upgrade, never *when*. Importing it without the driver is an eval
# error (the `autoUpdate.*` options won't exist); the two ship together
# in `flake.lib.bundles.nixos.auto-deploy`.
#
# Why not upstream `system.autoUpgrade`: that option is welded to a
# calendar timer (`startAt = cfg.dates` -> `OnCalendar`), which is
# exactly the design that failed here — see the history section in
# flake-modules/auto-update.nix. Bending it into shape means
# `mkForce`-ing away its `OnCalendar` and its `wantedBy = timers.target`
# and then bolting conditions onto a unit we don't own. The upgrade
# logic we actually want from it is one `nixos-rebuild switch` line, so
# we own the unit instead and keep upstream's option explicitly off.
#
# What the unit does:
#   nixos-rebuild switch --refresh --flake github:dc0d32/nixos#<host>
#
#   --refresh   force a re-fetch of the GitHub tarball instead of
#               reusing nix's cached copy, so a run actually picks up
#               new commits.
#   #<host>     explicit fragment. Without it nixos-rebuild infers the
#               configuration from `networking.hostName`, which works,
#               but being explicit means a mismatch fails loudly at eval
#               instead of quietly deploying nothing.
#
# What it deliberately does NOT do:
#   - **No `flake.lock` bumping.** The lock committed in the repo is
#     what every host deploys, so all hosts move in lockstep against the
#     same nixpkgs/niri/etc. revisions. Lock bumps are a manual
#     `nix flake update` on the dev box, tested, committed, pushed (plus
#     the update-flake-lock GitHub Action that opens a PR). Letting each
#     host resolve inputs at its own fire moment is the "auto-deploy
#     untested code" failure mode auto-update gets a bad name for.
#   - **No reboots.** Kernel/initrd updates land in the new generation
#     but only take effect when a human reboots. This is the single
#     biggest "you'll regret it" knob: a bad initrd auto-installed and
#     auto-rebooted on a headless or remote host is a brick with no
#     console. The unit logs a note when the kernel changed so the
#     reboot is at least visible.
#   - **No garbage collection.** GC is its own timer with its own
#     retention policy.
#
# `nixos-rebuild switch` daemon-reloads and restarts changed units
# mid-flight, so this unit — and the sequencer driving it — must carry
# `restartIfChanged = false` / `stopIfChanged = false` /
# `X-StopOnRemoval = false`, or the switch can tear down the very
# process performing it.
#
# Watching it:
#   auto-update-status
#   systemctl status nixos-auto-upgrade.service
#   journalctl -u nixos-auto-upgrade.service -n 200
# Running it by hand (bypasses the driver's gate entirely):
#   sudo systemctl start nixos-auto-upgrade.service
#
# Retire when: a different deployment driver replaces pull-based
#   auto-deploy (deploy-rs, or CI running `nixos-rebuild
#   --target-host`), OR the lock-in-the-repo policy changes and the
#   no-bump assumption above no longer holds.
{ ... }: {
  flake.modules.nixos.auto-upgrade = { config, pkgs, lib, ... }:
    let
      cfg = config.autoUpdate;
      hostName = config.networking.hostName;
      nixos-rebuild = "${config.system.build.nixos-rebuild}/bin/nixos-rebuild";
    in
    {
      # Upstream's calendar-timer implementation is explicitly off; this
      # module supersedes it. Stated rather than merely omitted so a
      # future reader doesn't "helpfully" switch it back on and end up
      # with two competing rebuild units.
      system.autoUpgrade.enable = false;

      # Register with the driver. mkOrder 100 puts the system rebuild
      # ahead of the home-manager pass (mkOrder 200) so HM activates
      # against the freshly-switched system closure.
      autoUpdate.steps = lib.mkOrder 100 [ "nixos-auto-upgrade.service" ];

      systemd.services.nixos-auto-upgrade = {
        description = "NixOS system upgrade from ${cfg.flake}#${hostName}";

        # Started by auto-update.service (or by hand), never by a timer
        # and never wanted by a target.
        wantedBy = [ ];

        restartIfChanged = false;
        stopIfChanged = false;
        unitConfig.X-StopOnRemoval = false;

        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];

        environment = config.nix.envVars // {
          inherit (config.environment.sessionVariables) NIX_PATH;
          HOME = "/root";
        } // config.networking.proxy.envVars;

        path = with pkgs; [
          coreutils
          gnutar
          xz.bin
          gzip
          gitMinimal
          config.nix.package.out
          config.programs.ssh.package
        ];

        script = ''
          set -euo pipefail
          echo "nixos-auto-upgrade: switching to ${cfg.flake}#${hostName}"
          ${nixos-rebuild} switch --refresh --flake '${cfg.flake}#${hostName}'
          echo "nixos-auto-upgrade: now on $(readlink -f /run/current-system)"
          booted=$(readlink -f /run/booted-system/kernel || echo unknown)
          current=$(readlink -f /run/current-system/kernel || echo unknown)
          if [ "$booted" != "$current" ]; then
            echo "nixos-auto-upgrade: NOTE kernel changed; a reboot is required for it to take effect (auto-reboot is disabled on purpose)"
          fi
        '';

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          # Cold substituters on a slow link make a full closure fetch
          # genuinely long. The driver's own TimeoutStartSec bounds the
          # whole sequence.
          TimeoutStartSec = "2h";
        };
      };
    };
}
