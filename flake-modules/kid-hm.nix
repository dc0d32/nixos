# Shared helpers for the kids' accounts (m, s).
#
# Two host bridges (m-pc, pb-t480) produce home-manager configs and
# timekpr policies for the same kids. Before this module each bridge
# hand-rolled a `mkKidHmModule` and an identical `kidPolicy` attrset,
# which invited drift between the two hosts the kids actually use
# interchangeably. This publishes both once on `flake.lib`.
#
# - flake.lib.mkKidHmModule { username; audio; stateVersion ? … }
#     The per-kid HM module (kid bundle + freecad, restricted GUI).
# - flake.lib.kidTimekprPolicy
#     The shared screen-time policy (same kids, same school schedule).
#
# Both live under flake.lib (the documented escape hatch for arbitrary
# helpers; see flake-modules/mk-pkgs.nix and flake-modules/lib.nix).
#
# Retire when: the kids age out and their accounts merge with the adult
#   desktop bundle, OR only one host serves the kids (no cross-host
#   policy/module to keep in sync).
{ config, ... }:
{
  # Shared timekpr policy. See the long comment in
  # flake-modules/hosts/pb-t480.nix for the weekday/weekend rationale
  # (window vs budget are independent axes; Sunday curfew is tight
  # because Monday is school).
  #
  # The budget is ONE pool spent across every host that runs the
  # timekpr-sync agent (flake-modules/timekpr-sync.nix) against the
  # controller on ursa. Hosts that don't run the agent — or any host
  # while the controller is unreachable — fall back to enforcing this
  # same number locally, per host.
  flake.lib.kidTimekprPolicy = {
    allowedHoursByDay = {
      mon = "06:00-22:00";
      tue = "06:00-22:00";
      wed = "06:00-22:00";
      thu = "06:00-22:00";
      fri = "06:00-23:00";
      sat = "06:00-23:00";
      sun = "06:00-22:00";
    };
    dailyBudgetMinutesByDay = {
      mon = 240;
      tue = 240;
      wed = 240;
      thu = 240;
      fri = 240;
      sat = 360;
      sun = 360;
    };
    # Lock the screen, never terminate the session. The default
    # (`terminate`) SIGTERM/SIGKILLs everything the kid had open the
    # instant the budget or the curfew boundary is hit — i.e. it destroys
    # unsaved work as a matter of routine, several times a week. That is a
    # support burden and it teaches them the enforcement is the enemy.
    #
    # `lock` calls the logind session's .Lock() (server/interface/dbus/
    # logind/user.py::lockUserSessions, gated on session Type being one of
    # x11/wayland/mir — a niri session reports `wayland`, so it matches).
    # swayidle's `lock` event handler is already listening for exactly that
    # signal on these hosts (flake-modules/idle.nix) and raises
    # swaylock-effects. Their work stays open behind the lockscreen.
    #
    # This does NOT weaken enforcement: unlocking with their password just
    # puts them back in front of a daemon that still sees zero time left,
    # and it re-locks on its next poll. And with TRACK_INACTIVE = false
    # (the default here) a locked screen stops consuming budget, so a lock
    # can't quietly eat the next day's allowance either.
    lockoutType = "lock";
  };

  # Where the shared-budget controller lives, and the token the agents
  # present on POST /report. Single source of truth so a host bridge and
  # ursa can't drift apart.
  #
  # `reportToken` is checked into git ON PURPOSE, and is NOT a secret:
  #
  #   * It authorizes exactly one operation — "add usage for (host,user)".
  #     The controller stores usage as max(stored, reported), so the only
  #     thing a holder can do is make a kid's day SHORTER. There is no
  #     reachable state where knowing this string buys anyone screen time.
  #   * It could not be a secret even if we wanted it to be: it is baked
  #     into the agent's spec file in /nix/store, which is world-readable
  #     on the kids' own laptops. A tokenFile would only move the same
  #     string somewhere marginally less obvious.
  #
  # Granting time, and every other privileged action, is behind the
  # dashboard's basic auth, whose password stays OUT of git in
  # /persist/secrets/timekpr-dashboard.pass on ursa. That is the real
  # credential. Do not put it here.
  flake.lib.timekprCentral = {
    url = "https://screentime.bitset.cc";
    reportToken = "yrXGIiw08Cmg4FQ9oJnb8f0E8GGzlurv";
  };

  # Per-kid home-manager module factory. idle timings and EDITOR/VISUAL
  # are module defaults now (flake-modules/idle.nix, flake-modules/vim.nix),
  # so they no longer need to be set per-kid.
  # `displays` mirrors the primary user's display layout so every
  # account on a shared host sees identical monitor behaviour — a kid
  # docking the family laptop should get the same arrangement p does.
  # Defaults to `{ }` (niri auto-detects) for hosts that don't care.
  flake.lib.mkKidHmModule = { username, audio, displays ? { }, stateVersion ? "25.11" }: {
    imports = config.flake.lib.bundles.homeManager.kid ++ [
      # FreeCAD is opt-in per-host since 2026-05-16; the kid bundle no
      # longer carries it, but the kids have always had it.
      config.flake.modules.homeManager.freecad
    ];

    programs.home-manager.enable = true;

    # EasyEffects per-host data (shared with the primary user on the
    # same host).
    inherit audio;

    displays.outputs = displays;

    home.username = username;
    home.homeDirectory = "/home/${username}";
    home.stateVersion = stateVersion;
  };
}
