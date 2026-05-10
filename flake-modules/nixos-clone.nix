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
# `git clone https://github.com/dc0d32/nixos ~/nixos` invocation —
# and on already-installed hosts that predate scripts/host-setup.sh's
# install-time clone step, that ceremony has never happened. This
# module backfills it on the next NixOS rebuild.
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
    in
    {
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
              # `git clone` into a fresh dir. If `~/nixos` exists
              # but isn't a git repo (e.g. user mkdir'd it for some
              # other purpose), this command refuses — surfacing
              # the conflict in the journal rather than silently
              # turning their dir into a clone.
              ExecStart =
                "${pkgs.git}/bin/git clone ${cloneUrl} /home/${user}/nixos";
              # Network-bound clone of a small repo; 5min is
              # generous even on a slow link.
              TimeoutStartSec = "5min";
            };
          })
        forThisHost;
    };
}
