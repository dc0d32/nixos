# nixos-clone — auto-clones https://github.com/dc0d32/nixos to
# `~/nixos` for every HM-enabled user on this host, once per user.
#
# Why: hosts that auto-upgrade NixOS (see auto-upgrade.nix) get the
# system closure refreshed nightly from `github:dc0d32/nixos`, but
# users still need a local checkout to:
#   - run `home-manager switch --flake ~/nixos#'<user>@<host>'` for
#     ad-hoc HM updates between auto-rebuilds (or instead of waiting
#     for them),
#   - inspect the config that produced their environment,
#   - hack on the repo and `nh os switch` from the working tree
#     (wheel users only).
# Without this module, every user has to remember the long
# `git clone https://github.com/dc0d32/nixos ~/nixos` invocation.
# This module performs that clone declaratively on first boot.
#
# How: for every HM configuration named `<user>@<hostname>` matching
# this host's hostname, contribute a oneshot systemd service
# `nixos-clone-<user>.service` that runs `git clone <url> ~/nixos`
# as that user, plus a timer that keeps retrying until it lands.
# Idempotency comes from
#   ConditionPathExists=!/home/<user>/nixos/.git
# so every fire after the first success is a microsecond no-op.
#
# ── This is a guarantee, not a nicety ────────────────────────────────
# `~/nixos` is the fallback you reach for *when auto-update has
# failed* — the checkout you `home-manager switch --flake ~/nixos#…`
# from by hand. That makes its delivery path load-bearing, and it must
# not share fate with the thing it rescues you from.
#
# Two independent triggers, on purpose:
#   1. `nixos-clone-<user>.timer` — OnBootSec=2min, then OnCalendar
#      hourly, ungated. This is the one that matters.
#   2. `autoUpdate.bestEffortSteps` — the auto-update sequencer also
#      runs it ahead of each system rebuild, so `sudo auto-update-now`
#      guarantees a checkout too.
#
# (1) exists because (2) alone would be circular: every condition that
# stops auto-update — on battery, outside the quiet window, inside the
# 6h throttle, offline, or simply broken — would also stop the clone.
#
# Earlier revisions of this module had a single `WantedBy=
# multi-user.target` trigger and no retry. `Type=oneshot` forbids
# `Restart=`, so that meant exactly ONE attempt per boot: a transient
# DNS hiccup while WiFi was still associating, on a desktop rebooted
# monthly, left the clone silently absent for weeks. Observed on m-pc,
# where `~/nixos` for user `m` had to be created by hand.
#
# `OnBootSec` + `OnCalendar` rather than `OnUnitActiveSec`: a unit
# that keeps being condition-skipped never *becomes* active, so an
# activity-relative timer would arm once and never re-fire.
#
# Consequence worth knowing: deleting `~/nixos` now gets it recreated
# within the hour. To keep a checkout elsewhere, leave a `.git` at the
# default path or drop this module from the host.
#
# User enumeration mirrors home-manager-bootstrap.nix exactly: same
# `<user>@<hostname>` naming convention, same outerHm capture
# trick. Importing this module on a host where home-manager-
# bootstrap.nix is also imported gives you parity between the
# bootstrap set and the clone set automatically.
#
# Network gating: `Wants=network-online.target` +
# `After=network-online.target` for the boot-time fire. If wait-online
# times out (e.g. WiFi never authenticated), the unit fails — and the
# hourly timer picks it up, rather than waiting for the next reboot.
#
# The checkout is for reading, hacking and manual activation. It is
# NEVER the source of an automatic upgrade: both real auto-update
# steps fetch `github:dc0d32/nixos` into the nix store as root, so a
# dirty or stale `~/nixos` cannot affect what gets deployed. Nothing
# here ever pulls, fetches or resets an existing checkout.
#
# HTTPS over SSH: the clone URL is HTTPS (`https://github.com/…`)
# so no per-user SSH key is required. Users who want to push from
# their clone can swap the remote to SSH manually:
#   cd ~/nixos
#   git remote set-url origin git@github.com:dc0d32/nixos.git
# (or just keep HTTPS and use a credential helper / PAT). Pushing
# from these clones is not the recommended workflow anyway — push
# from a workstation where you've reviewed `git status` carefully,
# not from a kid's laptop running an auto-pulled tree.
#
# Scope: this is opt-in per host (Pattern A — importing IS enabling).
# Hosts that don't want auto-cloning don't import. Currently wired
# on the same hosts that import auto-upgrade.nix; the two modules
# go hand-in-hand: auto-upgrade keeps the system in sync with
# `origin/main`, nixos-clone keeps each user's local checkout
# available for HM activation and inspection.
#
# Architecture note: same as home-manager-bootstrap.nix — captures
# `config.flake.homeConfigurations` from the outer flake-parts
# config so the inner NixOS-class module can enumerate the right
# user set. No coupling to home-manager-as-a-NixOS-module.
#
# Retire when: every host has a usable `~/nixos` for every HM user
# AND we're confident no fresh installs / new users will need
# backfilling, OR a different mechanism (e.g. a user-facing helper
# that clones on first login) supersedes this.
flakeArgs@{ config, lib, ... }:
let
  outerHm = config.flake.homeConfigurations;
in
{
  options.nixos-clone = {
    url = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/dc0d32/nixos";
      description = ''
        HTTPS URL to clone into each HM-enabled user's `~/nixos`.
        HTTPS is the default because it requires no per-user SSH
        key. Override per-host only if you've forked the repo and
        want hosts to track your fork.
      '';
    };
  };

  config.flake.modules.nixos.nixos-clone =
    { config, pkgs, lib, ... }:
    let
      hostName = config.networking.hostName;
      forThisHost = lib.filterAttrs
        (cfgName: _: lib.hasSuffix "@${hostName}" cfgName)
        outerHm;
      cloneUrl = flakeArgs.config.nixos-clone.url;

      users = lib.mapAttrsToList
        (cfgName: _: lib.elemAt (lib.splitString "@" cfgName) 0)
        forThisHost;

      # A real script rather than a bare `git clone`, so the two
      # not-actually-an-error cases exit 0 instead of leaving the unit
      # in `failed`, and the one genuine error says what to do about it.
      #
      # The empty-directory case is not hypothetical: hosts with
      # impermanence pre-create `~/nixos` as an empty bind mount (the
      # persisted `userDirectories` list contains "nixos"), so the unit
      # always runs against a directory that already exists. `git clone`
      # into an existing *empty* directory is fine; into a non-empty one
      # it aborts, which is the behaviour we want but not a message
      # anyone would find on their own.
      cloneScript = pkgs.writeShellApplication {
        name = "nixos-clone-run";
        runtimeInputs = [ pkgs.git pkgs.coreutils pkgs.findutils pkgs.openssh ];
        text = ''
          url="$1"
          target="$2"

          if [ -e "$target/.git" ]; then
            echo "nixos-clone: $target is already a git repo, nothing to do"
            exit 0
          fi

          if [ -d "$target" ] \
            && [ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]; then
            echo "nixos-clone: $target exists, is not empty, and has no .git." >&2
            echo "nixos-clone: refusing to clone over it. Move it aside and" >&2
            echo "nixos-clone: re-run this unit, or clone by hand:" >&2
            echo "nixos-clone:   git clone $url $target" >&2
            exit 1
          fi

          echo "nixos-clone: cloning $url into $target"
          git clone "$url" "$target"
          echo "nixos-clone: done"
        '';
      };
    in
    {
      # ── Retry, independently of auto-update ─────────────────────
      #
      # Each clone unit gets its own hourly timer. This is deliberately
      # NOT delegated to the auto-update driver, even though the clone
      # is also registered there as a best-effort step (below).
      #
      # The reason is a circular dependency: `~/nixos` is the fallback
      # you reach for *when auto-update has failed* -- the checkout you
      # `home-manager switch --flake ~/nixos#...` from by hand. If its
      # only retry were the auto-update sequencer, then every condition
      # that stops auto-update (on battery, outside the quiet window,
      # inside the 6h throttle, offline, or simply broken) would also
      # stop the clone. The escape hatch would be behind the thing it
      # exists to rescue you from.
      #
      # So: cheap, ungated, hourly, on every host, for every user.
      # A `git clone` of this repo is a few MB and the unit is
      # condition-skipped in microseconds once `~/nixos/.git` exists
      # (and, thanks to RemainAfterExit, is a total no-op after a
      # success within the same boot).
      #
      # `OnBootSec` + `OnCalendar` are used rather than
      # `OnUnitActiveSec`, because a unit that keeps being
      # condition-skipped never *becomes* active, so an activity-relative
      # timer would arm once and never re-fire.
      systemd.timers = lib.mapAttrs'
        (cfgName: _hm:
          let user = lib.elemAt (lib.splitString "@" cfgName) 0; in
          lib.nameValuePair "nixos-clone-${user}" {
            description = "Retry ~${user}/nixos checkout until it exists";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              # Shortly after boot, then hourly forever. The unit's
              # ConditionPathExists makes every fire after the first
              # success free.
              OnBootSec = "2min";
              OnCalendar = "hourly";
              RandomizedDelaySec = "5min";
              AccuracySec = "1min";
            };
          })
        forThisHost;

      # Also run it from the auto-update sequencer, as a best-effort
      # step ahead of the system rebuild. Redundant with the timer
      # above by design -- it means `sudo auto-update-now` also
      # guarantees the checkout, and it closes the window where a host
      # is about to activate a new generation with no local checkout.
      #
      # best-effort, never required: a clone that fails for a persistent
      # reason (`~/nixos` exists, non-empty, not a repo) must not
      # withhold the driver's `last-success` stamp, or the staleness
      # fallback would turn every poll into a full rebuild.
      autoUpdate.bestEffortSteps =
        lib.mkOrder 50 (map (u: "nixos-clone-${u}.service") users);

      systemd.services = lib.mapAttrs'
        (cfgName: _hm:
          let
            user = lib.elemAt (lib.splitString "@" cfgName) 0;
          in
          lib.nameValuePair "nixos-clone-${user}" {
            description = "Clone ${cloneUrl} into /home/${user}/nixos";
            wantedBy = [ "multi-user.target" ];
            # Wait for actual connectivity — we're hitting GitHub
            # over HTTPS. Same gating as home-manager-bootstrap.
            wants = [ "network-online.target" ];
            after = [
              "network-online.target"
              "systemd-user-sessions.service"
            ];
            # Idempotency: skip if a clone (or any .git dir) already
            # exists at the target path. Deliberately removing the
            # clone DOES get it recreated -- within the hour, by the
            # timer above. Users who want `~/nixos` somewhere else
            # should leave a checkout (or at least a `.git`) at the
            # default path, or drop the module from their host.
            unitConfig.ConditionPathExists =
              "!/home/${user}/nixos/.git";
            serviceConfig = {
              Type = "oneshot";
              User = user;
              Group = "users";
              RemainAfterExit = true;
              Environment = [
                "HOME=/home/${user}"
                "PATH=${lib.makeBinPath [
                  pkgs.git
                  pkgs.coreutils
                  pkgs.openssh
                ]}"
              ];
              ExecStart =
                "${cloneScript}/bin/nixos-clone-run ${cloneUrl} /home/${user}/nixos";
              # Network-bound clone of a small repo; 5min is
              # generous even on a slow link.
              TimeoutStartSec = "5min";
            };
          })
        forThisHost;
    };
}
