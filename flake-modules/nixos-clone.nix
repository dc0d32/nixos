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
# as that user. Idempotency comes from
#   ConditionPathExists=!/home/<user>/nixos/.git
# so the unit is a no-op once the clone exists. Users who delete
# their clone deliberately can re-trigger it with
#   sudo systemctl start nixos-clone-<user>.service
# but it will not auto-recreate on its own — by design (lets
# advanced users move ~/nixos elsewhere without the unit clobbering
# their layout on next boot).
#
# User enumeration mirrors home-manager-bootstrap.nix exactly: same
# `<user>@<hostname>` naming convention, same outerHm capture
# trick. Importing this module on a host where home-manager-
# bootstrap.nix is also imported gives you parity between the
# bootstrap set and the clone set automatically.
#
# Network gating: `Wants=network-online.target` +
# `After=network-online.target`. If wait-online times out (e.g. WiFi
# never authenticated), the unit fails this boot — but
# ConditionPathExists still passes next boot, so it retries
# automatically until the clone succeeds.
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
      # Retried on every auto-update poll instead of only once per boot.
      # `Type=oneshot` forbids `Restart=`, and the unit is otherwise just
      # `WantedBy=multi-user.target`, so it gets exactly one attempt per
      # boot -- one transient DNS hiccup on a desktop that reboots
      # monthly means the clone silently never happens (observed on
      # m-pc). best-effort, not a required step: a clone that fails for a
      # persistent reason must not withhold the driver's `last-success`
      # stamp and turn every poll into a full rebuild.
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
            # exists at the target path. Users who removed their
            # clone deliberately can re-trigger via
            #   systemctl start nixos-clone-<user>.service
            # but the unit won't recreate on its own.
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
