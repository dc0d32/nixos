# Nix daemon settings — flakes + experimental commands, store
# optimisation, weekly two-stage GC (age + count floor), allowUnfree,
# allowAliases off, repo-wide overlays.
#
# Pattern A: hosts opt in by importing this module. WSL hosts may
# choose not to import (the upstream WSL fork manages a separate Nix
# config); on bare-metal hosts these defaults apply.
#
# All scalars use mkDefault so any host that *does* import this can
# still override individual knobs without mkForce. Lists (like
# experimental-features) merge automatically.
#
# allowAliases is set to false to silence deprecated-rename warnings
# (e.g. the recurring nvim-treesitter-legacy one) on every rebuild.
# Pinned nixos-unstable: we deliberately update inputs and don't need
# the shims.
#
# Why a custom GC service instead of nix.gc.{automatic,dates,options}:
# we want BOTH "delete generations older than 14 days" AND "always keep
# at least the 15 most recent generations." The built-in
# `nix.gc.options = "--delete-older-than 14d"` runs nix-collect-garbage
# with that single flag, which doesn't accept a count floor. To compose
# both rules we run a tiny two-stage script weekly:
#   1. nix-collect-garbage --delete-older-than 14d
#      → drops anything older than 14d, EXCEPT the current generation
#      (nix-env's own safety rule) and except generations protected by
#      live store roots.
#   2. nix-env -p /nix/var/nix/profiles/system --delete-generations +15
#      → if step 1 left more than 15 generations (because they're all
#      <14d old, e.g. heavy rebuild week), trim to the 15 most recent.
#      If step 1 left fewer than 15, this is a no-op.
# Net effect: at steady state you have between 1 and 15 system
# generations on disk, none older than 14d unless you genuinely rebuild
# less often than that (in which case you keep at least one — the
# current one — for rollback safety).
#
# Mirrors the HM-side timer in flake-modules/nix-settings-hm.nix, which
# applies the same policy to the user profile and HM generations.
#
# Retire when: NixOS upstream defaults converge on flakes-on, weekly-GC,
#   store-optimisation, and allowAliases-off such that this opinionated
#   wrapper stops adding value, OR the repo-wide overlays move to a
#   different injection point, OR nix.gc.options grows native support
#   for "+N" (count floor) so the custom timer becomes redundant.
{ ... }:
{
  flake.modules.nixos.nix-settings = { lib, pkgs, ... }: {
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = lib.mkDefault true;
      warn-dirty = lib.mkDefault false;
    };

    # Two-stage GC: age sweep, then count floor. See module header for
    # the full rationale. Runs weekly; manually invokable via
    # `systemctl start nix-gc-twostage.service`.
    systemd.services.nix-gc-twostage = {
      description = "Two-stage Nix GC: --delete-older-than 14d, then keep 15 newest";
      # serviceConfig gets a writable /tmp by default; that's enough.
      serviceConfig = {
        Type = "oneshot";
        # nix-collect-garbage and nix-env --delete-generations on the
        # system profile both need root.
        User = "root";
      };
      # Stage 1: age-based prune across all profiles the daemon knows
      # about (system, per-user). Stage 2: count floor on the system
      # profile specifically (this is the one wired into the boot
      # loader, so it's the one whose generation count we care about
      # for boot-menu cleanliness).
      script = ''
        set -eu
        echo "Stage 1: nix-collect-garbage --delete-older-than 14d"
        ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 14d
        echo "Stage 2: keep last 15 system profile generations"
        ${pkgs.nix}/bin/nix-env --profile /nix/var/nix/profiles/system \
          --delete-generations +15
      '';
    };
    systemd.timers.nix-gc-twostage = {
      description = "Weekly two-stage Nix GC";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        # If the machine was off at the scheduled time, run on next
        # boot (matches the convenience of nix.gc.persistent=true).
        Persistent = true;
        # Add up to 1h jitter so multiple machines don't all GC at the
        # same Sunday-midnight moment.
        RandomizedDelaySec = "1h";
      };
    };

    nixpkgs.config.allowUnfree = lib.mkDefault true;
    nixpkgs.config.allowAliases = lib.mkDefault false;
    # Apply the flake-wide overlays. See overlays/default.nix.
    nixpkgs.overlays = import ../overlays;
  };
}
