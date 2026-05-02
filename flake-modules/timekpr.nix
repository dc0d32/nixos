# Timekpr-nExT — per-user screen-time and curfew enforcement, the
# Windows Family Safety equivalent for NixOS. Uses the upstream
# `timekpr` package shipped by nixpkgs (same project — Launchpad name
# `timekpr-next`, attribute name `pkgs.timekpr`). Importing this module
# enables the system daemon and creates the `timekpr` group; admins
# (e.g. the host's primary user) get added to that group separately by
# the host bridge so they can drive `timekpra` / `timekprc`.
#
# Pattern A: importing this module IS enabling timekpr on the host.
# There is no per-feature `enable` gate.
#
# Top-level options:
#   timekpr.users = { "<username>" = { allowedHours; dailyBudgetMinutes;
#                                      allowedHoursByDay; dailyBudgetMinutesByDay;
#                                      lockoutType; trackInactive; }; ... };
#
# Two ways to express the daily window and budget:
#
#   1. Uniform (same every day):
#        allowedHours = "06:00-21:00";
#        dailyBudgetMinutes = 240;
#
#   2. Per-weekday variation:
#        allowedHoursByDay = {
#          mon = "06:00-22:00"; tue = "06:00-22:00"; wed = "06:00-22:00";
#          thu = "06:00-22:00"; fri = "06:00-23:00"; sat = "06:00-23:00";
#          sun = "06:00-22:00";
#        };
#        dailyBudgetMinutesByDay = {
#          mon = 240; tue = 240; wed = 240; thu = 240;
#          fri = 240; sat = 360; sun = 360;
#        };
#
# Use one form or the other per axis; setting both for the same axis
# is a config-time assertion error. The two axes are independent —
# you may use the uniform form for hours and per-day for budget, or
# vice versa.
#
# `allowedHours` is an "HH:MM-HH:MM" string per day. Minutes inside
# the hour are ignored by timekpr's hour-grain accounting but the
# string is the most readable input format. We translate to timekpr's
# `ALLOWED_HOURS_<1-7> = h;h;h;...` semicolon list at render time.
# Hours are inclusive on the start and EXCLUSIVE on the end:
# "06:00-22:00" allows 06:00..21:59 and blocks 22:00.
#
# `dailyBudgetMinutes` is the per-day usage budget; rendered into
# `LIMITS_PER_WEEKDAYS` as seven values.
#
# Per-user files are seeded into /var/lib/timekpr/config/timekpr.<user>.conf
# via systemd.tmpfiles `C` (copy-if-missing) rules so the daemon's own
# rewrites (when admin uses the GUI/CLI to adjust limits at runtime)
# survive across reboots.
#
# IMPORTANT — applying a policy change to an already-deployed host:
# Because the seed files use `C` semantics, editing this module or
# the host's `timekpr.users.*` block and running `nixos-rebuild
# switch` is NOT enough on a host that already has the file: the
# pre-existing /var/lib/timekpr/config/timekpr.<user>.conf wins and
# the daemon keeps the old policy. To re-apply the declared values:
#
#     sudo rm /var/lib/timekpr/config/timekpr.<user>.conf
#     sudo nixos-rebuild switch --flake .#<host>
#     sudo systemctl restart timekpr
#
# This is by design — admin's ad-hoc runtime adjustments via
# `timekpra` should not get clobbered by every system rebuild.
# A fresh install (no file present) gets the declared defaults
# automatically; only updates need the manual reset.
#
# Retire when: NixOS upstream grows a `services.timekpr` module (none
# at time of writing — only `services.timekpr-next` exists in flake-
# parts hearsay; nixpkgs HEAD ships no such thing), OR when this
# household stops needing parental controls.
{ lib, config, ... }:
let
  cfg = config.timekpr;

  # Day-of-week names in the order timekpr's ALLOWED_HOURS_<n> /
  # LIMITS_PER_WEEKDAYS slots use them: ISO weekday numbering with
  # Monday=1 ... Sunday=7. The renderer iterates this list.
  dayNames = [ "mon" "tue" "wed" "thu" "fri" "sat" "sun" ];

  # Type for a per-day attrset: every key in dayNames must be present.
  # Submodule with one option per day forces exhaustive specification
  # (a missing day is a build-time error pointing at the missing
  # attribute, not a silent default to "off"). Each value is the
  # leaf type passed in.
  byDayType = leafType: lib.types.submodule {
    options = lib.genAttrs dayNames (_: lib.mkOption {
      type = leafType;
    });
  };

  # Per-user config submodule.
  userOpts = { name, ... }: {
    options = {
      allowedHours = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "06:00-21:00";
        description = ''
          Allowed login window for this user, as "HH:MM-HH:MM" in 24h
          local time. Applied to all seven weekdays uniformly. Hours
          outside this window are blocked (the daemon will terminate
          the session per `lockoutType`). Note: timekpr's accounting
          grain is one hour, so the minute fields are ignored
          internally — the start hour is always inclusive and the end
          hour is exclusive (e.g. "06:00-21:00" allows 06:00..20:59,
          blocks 21:00..05:59).

          Mutually exclusive with `allowedHoursByDay`. Set exactly one.
        '';
      };
      allowedHoursByDay = lib.mkOption {
        type = lib.types.nullOr (byDayType lib.types.str);
        default = null;
        example = lib.literalExpression ''
          {
            mon = "06:00-22:00"; tue = "06:00-22:00"; wed = "06:00-22:00";
            thu = "06:00-22:00"; fri = "06:00-23:00"; sat = "06:00-23:00";
            sun = "06:00-22:00";
          }
        '';
        description = ''
          Per-weekday allowed login windows. All seven days
          (mon, tue, wed, thu, fri, sat, sun) MUST be specified;
          a missing day is a build-time error.

          Mutually exclusive with `allowedHours`. Set exactly one.
        '';
      };
      dailyBudgetMinutes = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 240;
        description = ''
          Total daily usage budget in minutes, applied uniformly
          across all seven weekdays. Independent of `allowedHours`
          — the user is allowed to log in only during the window AND
          only for this much accumulated time per day, whichever
          runs out first.

          Mutually exclusive with `dailyBudgetMinutesByDay`. Set
          exactly one.
        '';
      };
      dailyBudgetMinutesByDay = lib.mkOption {
        type = lib.types.nullOr (byDayType lib.types.ints.positive);
        default = null;
        example = lib.literalExpression ''
          {
            mon = 240; tue = 240; wed = 240; thu = 240;
            fri = 240; sat = 360; sun = 360;
          }
        '';
        description = ''
          Per-weekday daily usage budgets in minutes. All seven days
          (mon..sun) MUST be specified; a missing day is a build-time
          error.

          Mutually exclusive with `dailyBudgetMinutes`. Set exactly
          one.
        '';
      };
      lockoutType = lib.mkOption {
        type = lib.types.enum [ "lock" "suspend" "suspendwake" "terminate" "kill" "shutdown" ];
        default = "terminate";
        description = ''
          What the daemon does when a user runs out of time or hits a
          curfew boundary. `terminate` (default) sends SIGTERM/SIGKILL
          to the session; `lock` invokes the screen lock; `suspend`
          puts the box to sleep; `shutdown` powers off.
        '';
      };
      trackInactive = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When false (default), idle time (locked screen, switched-away
          desktop) does NOT count against the daily budget. When true,
          all wall-clock time during the allowed window counts.
        '';
      };
    };
  };

  # Validate that exactly one of {uniform, byDay} is set on each
  # axis. Returns the user attrset unchanged on success; throws a
  # clear, user-readable message on misconfiguration.
  validateUser = username: u:
    let
      hoursUniform = u.allowedHours != null;
      hoursByDay = u.allowedHoursByDay != null;
      budgetUniform = u.dailyBudgetMinutes != null;
      budgetByDay = u.dailyBudgetMinutesByDay != null;
    in
    if hoursUniform && hoursByDay then
      throw "timekpr: user '${username}' sets both `allowedHours` and `allowedHoursByDay`; pick one."
    else if !hoursUniform && !hoursByDay then
      throw "timekpr: user '${username}' must set either `allowedHours` or `allowedHoursByDay`."
    else if budgetUniform && budgetByDay then
      throw "timekpr: user '${username}' sets both `dailyBudgetMinutes` and `dailyBudgetMinutesByDay`; pick one."
    else if !budgetUniform && !budgetByDay then
      throw "timekpr: user '${username}' must set either `dailyBudgetMinutes` or `dailyBudgetMinutesByDay`."
    else u;

  # Render an "HH:MM-HH:MM" string into a semicolon-separated list of
  # allowed hour numbers (start inclusive, end exclusive) suitable for
  # ALLOWED_HOURS_<n>.
  renderAllowedHours = window:
    let
      m = builtins.match "([0-9]+):([0-9]+)-([0-9]+):([0-9]+)" window;
      _ =
        if m == null
        then throw "timekpr: allowedHours must match HH:MM-HH:MM, got: ${window}"
        else null;
      # Strip leading zeros before lib.toInt — it rejects "06" as
      # ambiguous between octal and decimal even though we always
      # mean decimal here.
      stripZeros = s:
        let s' = lib.removePrefix "0" s;
        in if s' == "" then "0"
        else if lib.hasPrefix "0" s' then stripZeros s'
        else s';
      startH = lib.toInt (stripZeros (builtins.elemAt m 0));
      endH = lib.toInt (stripZeros (builtins.elemAt m 2));
      _check =
        if startH < 0 || startH > 23 || endH < 0 || endH > 24 || startH >= endH
        then throw "timekpr: allowedHours invalid range: ${window}"
        else null;
      hours = lib.range startH (endH - 1);
    in
    lib.concatStringsSep ";" (map toString hours);

  # For a given user, build the seven (allowed-hours-string, budget-
  # minutes) pairs in mon..sun order. Picks the *ByDay value if set,
  # otherwise falls back to the uniform value (which we know is set
  # because validateUser ran first).
  perDay = u:
    let
      hoursFor = day:
        if u.allowedHoursByDay != null
        then u.allowedHoursByDay.${day}
        else u.allowedHours;
      budgetFor = day:
        if u.dailyBudgetMinutesByDay != null
        then u.dailyBudgetMinutesByDay.${day}
        else u.dailyBudgetMinutes;
    in
    map
      (day: {
        hours = renderAllowedHours (hoursFor day);
        budgetSec = budgetFor day * 60;
      })
      dayNames;

  # Render a per-user config file body.
  renderUserConf = username: rawU:
    let
      u = validateUser username rawU;
      days = perDay u;
      # Helper: emit ALLOWED_HOURS_<n> lines as a single multiline
      # string. Slots are 1-indexed, mon=1..sun=7.
      hoursLines = lib.concatStringsSep "\n" (lib.imap1
        (i: d: "ALLOWED_HOURS_${toString i} = ${d.hours}")
        days);
      limitsList = lib.concatStringsSep ";" (map (d: toString d.budgetSec) days);
      weekTotalSec = lib.foldl' (acc: d: acc + d.budgetSec) 0 days;
      # Month total: approximate by averaging week-total over 4.43
      # weeks per month. Uses integer math (no floats in nix). The
      # exact value isn't policy-critical — timekpr enforces the
      # daily and weekly limits long before the monthly one bites.
      monthTotalSec = (weekTotalSec * 31) / 7;
    in
    ''
      [DOCUMENTATION]
      #### managed by flake-modules/timekpr.nix — initial seed only.
      #### the daemon may rewrite this file when admin uses timekpra/timekprc
      #### at runtime. delete the file and rebuild to re-apply declared defaults.

      [USER]
      ${hoursLines}
      ALLOWED_WEEKDAYS = 1;2;3;4;5;6;7
      LIMITS_PER_WEEKDAYS = ${limitsList}
      LIMIT_PER_WEEK = ${toString weekTotalSec}
      LIMIT_PER_MONTH = ${toString monthTotalSec}
      TRACK_INACTIVE = ${if u.trackInactive then "True" else "False"}
      HIDE_TRAY_ICON = False
      LOCKOUT_TYPE = ${u.lockoutType}
      WAKEUP_HOUR_INTERVAL = 0;23

      [USER.PLAYTIME]
      PLAYTIME_ENABLED = False
      PLAYTIME_LIMIT_OVERRIDE_ENABLED = False
      PLAYTIME_UNACCOUNTED_INTERVALS_ENABLED = True
      PLAYTIME_ALLOWED_WEEKDAYS = 1;2;3;4;5;6;7
      PLAYTIME_LIMITS_PER_WEEKDAYS = 0;0;0;0;0;0;0
    '';
in
{
  options.timekpr = {
    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule userOpts);
      default = { };
      description = ''
        Per-user time policies. The attribute name is the unix
        username; the value declares that user's curfew window and
        daily budget. Users not listed here are not subject to
        timekpr enforcement (i.e. unrestricted from timekpr's POV).
      '';
    };
  };

  config.flake.modules.nixos.timekpr = { pkgs, ... }:
    let
      # Materialize each per-user config into the nix store, then
      # tmpfiles-copy it on first boot. We use copy (`C`) rather than
      # link (`L`) so the daemon can rewrite the file at runtime when
      # admin adjusts limits via timekpra; the rewrite persists across
      # reboots because tmpfiles `C` is "create only if missing".
      userSeedFiles = lib.mapAttrs
        (username: u: pkgs.writeText "timekpr.${username}.conf" (renderUserConf username u))
        cfg.users;

      tmpfilesUserRules = lib.mapAttrsToList
        (username: seedFile:
          "C /var/lib/timekpr/config/timekpr.${username}.conf 0644 root root - ${seedFile}"
        )
        userSeedFiles;
    in
    {
      # CLI/GUI tooling for admin (timekpra) and clients (timekprc) on
      # PATH for everyone; the daemon binary lives at the same prefix.
      environment.systemPackages = [ pkgs.timekpr ];

      # The upstream D-Bus policy (shipped under
      # ${pkgs.timekpr}/etc/dbus-1/system.d/timekpr.conf) restricts the
      # admin interface to the `timekpr` group. NixOS picks up
      # system.d snippets from packages listed here.
      services.dbus.packages = [ pkgs.timekpr ];

      # Polkit action shipped at ${pkgs.timekpr}/share/polkit-1/actions
      # — picked up by the systemwide polkit aggregation.
      environment.pathsToLink = [ "/share/polkit-1" ];

      # Group used by the D-Bus policy to authorize admin calls. GID
      # 2000 matches the upstream postinst convention (Debian/Ubuntu)
      # so the same `timekpr` group works identically across distros
      # if data is moved.
      users.groups.timekpr = {
        gid = 2000;
      };

      # Main daemon config: the package ships a fully-realized
      # /etc/timekpr/timekpr.conf with TIMEKPR_SHARED_DIR already
      # patched to the nix store; we just symlink it into /etc.
      environment.etc."timekpr/timekpr.conf".source =
        "${pkgs.timekpr}/etc/timekpr/timekpr.conf";

      # Logrotate snippet shipped by upstream (rotates /var/log/timekpr*).
      environment.etc."logrotate.d/timekpr".source =
        "${pkgs.timekpr}/etc/logrotate.d/timekpr";

      # Seed per-user config files. tmpfiles `C` only writes if the
      # destination is missing, so the daemon's own runtime rewrites
      # (driven by timekpra) survive reboots.
      systemd.tmpfiles.rules = [
        "d /var/lib/timekpr 0755 root root -"
        "d /var/lib/timekpr/config 0755 root root -"
        "d /var/lib/timekpr/work 0755 root root -"
      ] ++ tmpfilesUserRules;

      # The daemon. The unit shipped at
      # ${pkgs.timekpr}/lib/systemd/system/timekpr.service uses
      # absolute store paths for ExecStart and WorkingDirectory, so
      # we just adopt it wholesale by listing the package as a
      # systemd package and enabling the unit.
      systemd.packages = [ pkgs.timekpr ];
      systemd.services.timekpr = {
        wantedBy = [ "multi-user.target" ];
      };
    };
}
