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
  # because Monday is school). Enforced PER HOST — a kid can spend the
  # budget once on each host they use.
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
