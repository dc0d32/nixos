# hm-auto-upgrade — daily `home-manager switch` per HM-enabled user
# against this flake's `origin/main` on GitHub.
#
# Why: `system.autoUpgrade` (see auto-upgrade.nix) refreshes the
# NixOS system closure nightly, but it does NOT touch any user's
# home-manager profile — by design (AGENTS.md: HM is standalone, not
# wired in as a NixOS module). Without this module, dotfile/zsh/
# quickshell/EasyEffects changes that ship via HM only land when
# the user manually runs
#   home-manager switch --flake github:dc0d32/nixos#'<user>@<host>'
# which on a kid's laptop or a headless homelab account never
# happens. This module closes that gap with a single system timer
# that activates each user's HM profile.
#
# Why a system timer, not per-user systemd-user timers:
#   - systemd-user units only run when the user has a session OR
#     `loginctl enable-linger <user>` has been set. Lingering every
#     HM user (kids, role accounts) is a deployment cliff (forgotten
#     linger = silently no-op timer).
#   - A single system timer is centrally observable
#     (`systemctl status hm-auto-upgrade.timer`,
#      `journalctl -u hm-auto-upgrade.service`) and naturally
#     ordered against `nixos-upgrade.service`.
#   - Running HM activation as the target user inside a system
#     service is straightforward via `runuser -u <user>`.
#
# Schedule: 05:30 local with 30min jitter, persistent. Staggered
# AFTER `nixos-upgrade.timer` (04:40 + 30min jitter, worst-case
# finish ~05:10) so HM activates against the freshly-rebuilt system
# closure rather than the previous generation. Persistent timer
# catches missed runs after a host was off.
#
# Ordering against clone units: `After=nixos-clone-<user>.service`
# for each HM user. The clone units themselves have an idempotent
# ConditionPathExists guard (see nixos-clone.nix) so they are no-ops
# once a clone exists. Ordering means: on the first boot after
# importing both modules, HM auto-upgrade waits for the clone to
# land (or fail-trying) before running. After clones are present,
# the After= relationship is essentially free.
#
# Source: pulled fresh from `github:dc0d32/nixos` each run via
# `nix run` with `--refresh`, mirroring how auto-upgrade.nix fetches
# the system flake. The user's local `~/nixos` clone is NOT used as
# the activation source — that would couple HM upgrades to whatever
# state the user left their working tree in (dirty tree, branch,
# stale fetch). Activating from `github:` is hermetic and matches
# what `system.autoUpgrade` does for the system closure.
#
# Failure policy: per-user activation failures are logged and the
# loop continues to the next user. The systemd service exits 0 even
# if some users failed — visible in `journalctl -u
# hm-auto-upgrade.service`. The alternative (exit non-zero on any
# failure) would mean a transient WiFi flake on user A blocks the
# timer's "succeeded last run" status and obscures real failures.
#
# Per-user activation is invoked via `nix run nixpkgs#home-manager`
# rather than relying on home-manager being on the system PATH, so
# this module has no dependency on a particular HM CLI being
# installed system-wide. The flake's pinned home-manager is what
# materializes the activation package via the
# `homeConfigurations.<user>@<host>` outputs anyway.
#
# Pattern A (importing IS enabling): hosts that want auto-HM-upgrade
# import this module from their bridge. There is no per-feature
# `enable` flag. Currently wired on the same hosts that import
# auto-upgrade.nix (pb-t480, ah-1, m-pc, wsl, wsl-arm — NOT pb-x1,
# the dev box).
#
# To watch what the timer is doing on a host:
#   systemctl status hm-auto-upgrade.timer
#   systemctl status hm-auto-upgrade.service
#   journalctl -u hm-auto-upgrade.service -n 200
#
# To trigger an HM upgrade manually (same code path the timer uses):
#   sudo systemctl start hm-auto-upgrade.service
#
# Retire when: a different deployment driver replaces this (e.g.
# push-based HM deploys from CI), OR home-manager grows a built-in
# auto-upgrade analog and we adopt that, OR the flake URL strategy
# changes (e.g. switch to per-user channel tracking).
flakeArgs@{ config, lib, ... }:
let
  outerHm = config.flake.homeConfigurations;
in
{
  flake.modules.nixos.hm-auto-upgrade =
    { config, pkgs, lib, ... }:
    let
      hostName = config.networking.hostName;
      forThisHost = lib.filterAttrs
        (cfgName: _: lib.hasSuffix "@${hostName}" cfgName)
        outerHm;
      users = lib.mapAttrsToList
        (cfgName: _: lib.elemAt (lib.splitString "@" cfgName) 0)
        forThisHost;
      cloneAfter = map (u: "nixos-clone-${u}.service") users;

      # Build the per-user activation loop. Each user's failure is
      # captured locally so the loop continues; the script always
      # exits 0 (failures visible in the journal).
      flakeUrl = "github:dc0d32/nixos";
      activateScript = pkgs.writeShellApplication {
        name = "hm-auto-upgrade-run";
        runtimeInputs = with pkgs; [
          nix
          coreutils
          util-linux # runuser
        ];
        text = ''
          set -u
          # Don't `set -e`: per-user failures must NOT abort the
          # loop. We track failures explicitly and report at the
          # end.
          fail_count=0
          fail_users=""

          # Activation pattern: `nix build --refresh ...` materializes
          # the per-user activationPackage (re-fetches the flake from
          # GitHub each run, mirroring system.autoUpgrade), printing
          # the resulting store path. Then we invoke
          # `<out>/activate` as the target user. We can't use
          # `nix run` because home-manager's activationPackage has no
          # default executable — `activate` is what HM's standard CLI
          # invokes too.
          #
          # The build runs as root (this service's User=root) so the
          # store path is created with root daemon perms; the
          # subsequent runuser activation only needs to read the
          # store path, which is world-readable.

          ${lib.concatMapStringsSep "\n" (user: ''
            echo
            echo "==> ${user}@${hostName}: building activationPackage from ${flakeUrl}"
            if out=$(nix \
                --extra-experimental-features "nix-command flakes" \
                build \
                  --refresh \
                  --no-link \
                  --print-out-paths \
                  '${flakeUrl}#homeConfigurations."${user}@${hostName}".activationPackage'); then
              echo "==> ${user}@${hostName}: built $out, activating"
              if runuser -u ${user} -- env \
                  HOME=/home/${user} \
                  XDG_CONFIG_HOME=/home/${user}/.config \
                  XDG_DATA_HOME=/home/${user}/.local/share \
                  XDG_STATE_HOME=/home/${user}/.local/state \
                  XDG_CACHE_HOME=/home/${user}/.cache \
                  PATH=/run/current-system/sw/bin:/run/wrappers/bin \
                  "$out/activate"; then
                echo "==> ${user}@${hostName}: ok"
              else
                rc=$?
                echo "==> ${user}@${hostName}: ACTIVATE FAILED (exit $rc)" >&2
                fail_count=$(( fail_count + 1 ))
                fail_users="$fail_users ${user}"
              fi
            else
              rc=$?
              echo "==> ${user}@${hostName}: BUILD FAILED (exit $rc)" >&2
              fail_count=$(( fail_count + 1 ))
              fail_users="$fail_users ${user}"
            fi
          '') users}

          echo
          if [ "$fail_count" -gt 0 ]; then
            echo ">> hm-auto-upgrade: $fail_count user(s) failed:$fail_users" >&2
            echo ">> hm-auto-upgrade: see journal entries above for details." >&2
            echo ">> hm-auto-upgrade: exiting 0 anyway (failures are non-fatal;" >&2
            echo "   timer will retry tomorrow)." >&2
          else
            echo ">> hm-auto-upgrade: all ${toString (lib.length users)} user(s) ok"
          fi
          exit 0
        '';
      };
    in
    lib.mkIf (users != [ ]) {
      systemd.services.hm-auto-upgrade = {
        description =
          "Daily home-manager switch for all HM users on ${hostName}";
        # Ordering: wait for the clone units (no-op if clones exist)
        # so a brand-new host's first auto-HM-upgrade doesn't race a
        # user's clone landing. Pure ordering — we do NOT
        # `Requires=` them, so a failed clone doesn't block HM
        # upgrade (HM activates from github: anyway, not from the
        # local clone).
        after = [ "network-online.target" ] ++ cloneAfter;
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          # Runs as root because it `runuser`s into each user.
          User = "root";
          ExecStart = "${activateScript}/bin/hm-auto-upgrade-run";
          # Activations can take minutes if substituters are cold;
          # bound the whole loop generously.
          TimeoutStartSec = "30min";
        };
      };

      systemd.timers.hm-auto-upgrade = {
        description =
          "Daily home-manager switch for all HM users on ${hostName}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # 05:30 local, 30min after the system auto-upgrade window
          # closes (04:40 + 30min jitter = up to ~05:10 finish).
          # Format: see systemd.time(7).
          OnCalendar = "*-*-* 05:30:00";
          # 30-minute jitter so multiple hosts don't hit GitHub at
          # the same second.
          RandomizedDelaySec = "30min";
          # Catch up after the host was off at 05:30.
          Persistent = true;
        };
      };
    };
}
