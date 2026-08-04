# hm-auto-upgrade — the user half of auto-deploy: activate every
# home-manager profile on this host from `origin/main` on GitHub.
#
# Why it's needed at all: home-manager runs *standalone* in this repo
# (AGENTS.md forbids wiring it in as a NixOS module, so the same user
# modules can also apply on macOS). That means
# `nixos-auto-upgrade.service` refreshing the system closure does
# nothing whatsoever to a user's dotfiles, zsh config, waybar, niri
# bindings or EasyEffects presets. Without this module those changes
# only land when someone types
#   home-manager switch --flake github:dc0d32/nixos#'<user>@<host>'
# which on a kid's laptop or a headless role account never happens.
#
# It contributes ONE unit, `hm-auto-upgrade.service`, and no timer:
# scheduling, gating and ordering belong to the driver,
# flake-modules/auto-update.nix, which runs this unit *after*
# `nixos-auto-upgrade.service` so HM activates against the freshly
# switched system closure. (The previous design gave this module its own
# 05:30 calendar timer 50 minutes after the system one, which held only
# as long as neither run was ever late — and on a persistent catch-up
# boot both timers elapsed simultaneously and raced.)
#
# ── Why a system service, not per-user systemd-user timers ───────────
# systemd-user units only run when the user has a session or has been
# granted `loginctl enable-linger`. Lingering every HM user (kids, role
# accounts) is a deployment cliff: one forgotten linger is a silently
# no-op timer. One system unit is centrally observable and trivially
# ordered against the system rebuild.
#
# ── Which users ──────────────────────────────────────────────────────
# Every `homeConfigurations.<user>@<thishost>` in the flake, discovered
# by capturing `config.flake.homeConfigurations` from the outer
# flake-parts config. Same enumeration trick as nixos-clone.nix and
# home-manager-bootstrap.nix, so all three cover exactly the same set
# automatically. On pb-t480 that is p, m and s — no per-host list to
# forget to update when a kid account is added.
#
# ── How each user is activated ───────────────────────────────────────
#   1. `nix build --refresh` the user's `activationPackage` as root.
#      Root does the build so there's one shared download, and the
#      resulting store path is world-readable.
#   2. Compare it against that user's current generation
#      (`~/.local/state/home-manager/gcroots/current-home`). Equal
#      means nothing changed for this user; skip. This keeps a run
#      cheap and keeps the journal readable, which matters when the
#      driver polls hourly.
#   3. `runuser -u <user> -- env … $out/activate`.
#
# Three details of step 3 that are load-bearing:
#
#   * **USER/LOGNAME are set explicitly.** home-manager's activate
#     script ends with `checkStringEq USER "$USER" <user>` and
#     `checkPathEq HOME "$HOME" <home>` and hard-exits 1 on mismatch.
#     runuser does set both itself, but this unit is the only thing
#     standing between a kid's laptop and silently never updating, so
#     it does not delegate that to a flag-dependent behaviour of
#     runuser.
#   * **HOME comes from `users.users.<user>.home`,** not a hardcoded
#     `/home/<user>`, so a user with a non-default home doesn't fail
#     the `checkPathEq` above forever.
#   * **XDG_RUNTIME_DIR + DBUS_SESSION_BUS_ADDRESS are passed when the
#     user actually has a session.** Without them the `systemctl --user`
#     calls inside HM activation can't reach the user's systemd
#     manager, so a logged-in user's waybar/mako/cliphist units keep
#     running the *old* config until they log out and back in — the
#     activation "succeeds" while visibly changing nothing. When there
#     is no session (`/run/user/<uid>` absent) we say so in the journal
#     and let the new config take effect at next login.
#
# ── Failure policy ───────────────────────────────────────────────────
# Per-user failures do not abort the loop — one user with a stale
# colliding dotfile must not stop the other two from updating. But the
# unit **exits non-zero** if any user failed, unlike the original
# version which always exited 0. Always-zero meant a user whose
# activation had been failing every night for weeks looked identical to
# a clean run in `systemctl status`, which is precisely how "not all
# users update" went unnoticed. Non-zero also means the driver does not
# advance its `last-success` stamp, so the staleness fallback keeps
# retrying instead of waiting for tomorrow's quiet window.
#
# Source is `github:dc0d32/nixos`, never the user's local `~/nixos`
# clone: activating from a working tree couples upgrades to whatever
# state the user left it in (dirty, on a branch, stale fetch).
# Hermetic, and matches what the system half does.
#
# Watching it:
#   auto-update-status
#   journalctl -u hm-auto-upgrade.service -n 200
# Running it by hand (bypasses the driver's gate):
#   sudo systemctl start hm-auto-upgrade.service
#
# Retire when: push-based HM deploys replace pull-based auto-deploy, OR
#   home-manager grows a built-in multi-user auto-upgrade analog and we
#   adopt it.
flakeArgs@{ config, ... }:
let
  outerHm = flakeArgs.config.flake.homeConfigurations;
in
{
  flake.modules.nixos.hm-auto-upgrade =
    { config, pkgs, lib, ... }:
    let
      cfg = config.autoUpdate;
      hostName = config.networking.hostName;

      forThisHost = lib.filterAttrs
        (cfgName: _: lib.hasSuffix "@${hostName}" cfgName)
        outerHm;
      users = lib.mapAttrsToList
        (cfgName: _: lib.elemAt (lib.splitString "@" cfgName) 0)
        forThisHost;

      # Prefer the account's real home over a `/home/<user>` guess:
      # home-manager's activation hard-fails on a HOME mismatch.
      homeOf = user:
        if config.users.users ? ${user}
        then config.users.users.${user}.home
        else "/home/${user}";

      cloneAfter = map (u: "nixos-clone-${u}.service") users;

      activateScript = pkgs.writeShellApplication {
        name = "hm-auto-upgrade-run";
        runtimeInputs = [
          # The system's nix, not `pkgs.nix`: this talks to the running
          # nix-daemon, and a client newer than the daemon is a
          # protocol-mismatch waiting to happen on a host that hasn't
          # switched yet.
          config.nix.package
          pkgs.coreutils
          pkgs.util-linux # runuser
        ];
        text = ''
          host=${lib.escapeShellArg hostName}
          flake=${lib.escapeShellArg cfg.flake}
          fail_count=0
          fail_users=""

          activate_user() {
            local user="$1" home="$2"
            local out current uid runtime
            local -a env_args

            echo
            echo "==> $user@$host: building activationPackage from $flake"
            if ! out=$(nix \
                --extra-experimental-features "nix-command flakes" \
                build \
                  --refresh \
                  --no-link \
                  --print-out-paths \
                  "$flake#homeConfigurations.\"$user@$host\".activationPackage"); then
              echo "==> $user@$host: BUILD FAILED" >&2
              return 1
            fi

            current=""
            if [ -L "$home/.local/state/home-manager/gcroots/current-home" ]; then
              current=$(readlink -f "$home/.local/state/home-manager/gcroots/current-home" || true)
            fi
            if [ -n "$current" ] && [ "$current" = "$out" ]; then
              echo "==> $user@$host: already on $out, nothing to do"
              return 0
            fi

            if ! uid=$(id -u "$user" 2>/dev/null); then
              echo "==> $user@$host: no such account on this host" >&2
              return 1
            fi

            env_args=(
              "HOME=$home"
              "USER=$user"
              "LOGNAME=$user"
              "XDG_CONFIG_HOME=$home/.config"
              "XDG_DATA_HOME=$home/.local/share"
              "XDG_STATE_HOME=$home/.local/state"
              "XDG_CACHE_HOME=$home/.cache"
              "PATH=/run/current-system/sw/bin:/run/wrappers/bin"
            )

            # With a live session, hand activation the user bus so its
            # `systemctl --user` calls actually restart waybar/mako/etc.
            # Without one, the profile still updates and the new units
            # start at next login.
            runtime="/run/user/$uid"
            if [ -d "$runtime" ]; then
              env_args+=(
                "XDG_RUNTIME_DIR=$runtime"
                "DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus"
              )
            else
              echo "==> $user@$host: no live session ($runtime absent); user services will pick up the change at next login"
            fi

            echo "==> $user@$host: activating $out"
            if runuser -u "$user" -- env "''${env_args[@]}" "$out/activate"; then
              echo "==> $user@$host: ok"
              return 0
            fi
            echo "==> $user@$host: ACTIVATION FAILED" >&2
            return 1
          }

          ${lib.concatMapStringsSep "\n" (user: ''
            if ! activate_user ${lib.escapeShellArg user} ${lib.escapeShellArg (homeOf user)}; then
              fail_count=$(( fail_count + 1 ))
              fail_users="$fail_users ${user}"
            fi
          '') users}

          echo
          if [ "$fail_count" -gt 0 ]; then
            echo ">> hm-auto-upgrade: $fail_count of ${toString (lib.length users)} user(s) failed:$fail_users" >&2
            exit 1
          fi
          echo ">> hm-auto-upgrade: all ${toString (lib.length users)} user(s) ok"
        '';
      };
    in
    lib.mkIf (users != [ ]) {
      # mkOrder 200: after the system rebuild (mkOrder 100).
      autoUpdate.steps = lib.mkOrder 200 [ "hm-auto-upgrade.service" ];

      systemd.services.hm-auto-upgrade = {
        description =
          "home-manager switch for all HM users on ${hostName}";

        # Started by auto-update.service (or by hand), never by a timer.
        wantedBy = [ ];

        # The system rebuild that ran just before this may have queued
        # restarts; don't let the switch stop this unit mid-activation.
        restartIfChanged = false;
        stopIfChanged = false;
        unitConfig.X-StopOnRemoval = false;

        # Ordering only, never `requires`: the clone units are
        # idempotent no-ops once `~/<user>/nixos` exists (see
        # nixos-clone.nix), and HM activates from github: regardless, so
        # a failed clone must not block the upgrade.
        after = [ "network-online.target" ] ++ cloneAfter;
        wants = [ "network-online.target" ];

        environment = {
          HOME = "/root";
        };

        serviceConfig = {
          Type = "oneshot";
          # Root, because it `runuser`s into each account.
          User = "root";
          ExecStart = "${activateScript}/bin/hm-auto-upgrade-run";
          TimeoutStartSec = "1h";
        };
      };
    };
}
