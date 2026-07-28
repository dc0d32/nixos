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
# by timekpr-seed-config.service, which re-copies a user's file whenever
# the DECLARED policy changes (it compares the seed's store path against a
# `.seed-<user>` stamp) and leaves it alone otherwise. So a policy edit +
# `nixos-rebuild switch` applies immediately, while ad-hoc runtime
# adjustments made with `timekpra` persist until the declaration next
# changes.
#
# HISTORY — two bugs that together meant this module enforced NOTHING from
# its introduction until 2026-07-28:
#
#  1. The user section was rendered as `[USER]`. timekpr reads the section
#     named after the user (`common/utils/config.py::loadUserConfiguration`
#     does `section = self._userName`). Every parameter read therefore
#     raised NoSectionError, which `_readAndNormalizeValue` swallows,
#     substituting defaults: LIMITS_PER_WEEKDAYS = 86400 x7 and
#     ALLOWED_HOURS = all 24. That trips `TK_CTRL_TNL` in
#     `server/user/userdata.py`, so clients displayed "Your time is not
#     limited today" and no limit was ever applied. The daemon then
#     rewrote the file with the correct section name and those unlimited
#     defaults, permanently erasing the declared policy.
#  2. Seeding used systemd.tmpfiles `C` (copy-only-if-missing), so fixing
#     (1) alone would never have reached an already-deployed host — the
#     unlimited file the daemon wrote in step (1) would win forever.
#
# Both are fixed. The stamp in (2) is what repairs existing hosts: they
# have no stamp file, so the corrected config is written on the next
# switch.
# A fresh install (no file present) gets the declared defaults
# automatically; only updates need the manual reset.
#
# Retire when: NixOS upstream grows a `services.timekpr` module (none
# at time of writing — only `services.timekpr-next` exists in flake-
# parts hearsay; nixpkgs HEAD ships no such thing), OR when this
# household stops needing parental controls.
{ lib, ... }:
let
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
      #### managed by flake-modules/timekpr.nix.
      #### re-seeded automatically whenever the declared policy changes
      #### (see the seed-stamp service below); runtime edits made with
      #### timekpra/timekprc survive until then.

      [${username}]
      ${hoursLines}
      ALLOWED_WEEKDAYS = 1;2;3;4;5;6;7
      LIMITS_PER_WEEKDAYS = ${limitsList}
      LIMIT_PER_WEEK = ${toString weekTotalSec}
      LIMIT_PER_MONTH = ${toString monthTotalSec}
      TRACK_INACTIVE = ${if u.trackInactive then "True" else "False"}
      HIDE_TRAY_ICON = False
      LOCKOUT_TYPE = ${u.lockoutType}
      WAKEUP_HOUR_INTERVAL = 0;23

      [${username}.PLAYTIME]
      PLAYTIME_ENABLED = False
      PLAYTIME_LIMIT_OVERRIDE_ENABLED = False
      PLAYTIME_UNACCOUNTED_INTERVALS_ENABLED = True
      PLAYTIME_ALLOWED_WEEKDAYS = 1;2;3;4;5;6;7
      PLAYTIME_LIMITS_PER_WEEKDAYS = 0;0;0;0;0;0;0
    '';
in
{
  # Options live INSIDE the NixOS module, not at the flake-parts top
  # level. Declaring them outside makes them a single shared option
  # across the whole flake, so every host that sets `timekpr.users`
  # merges its definition into the same attrset and all of them get the
  # union. That is not hypothetical: it put a `timekpr.s.conf` on m-pc,
  # where user `s` does not exist, purely because pb-t480 declares `s`.
  # It also made per-host policy divergence impossible. Same failure the
  # `timekpr-sync` module had, which went unnoticed only because
  # `types.str` silently merges byte-identical definitions.
  flake.modules.nixos.timekpr = { config, pkgs, ... }:
    let
      cfg = config.timekpr;

      userSeedFiles = lib.mapAttrs
        (username: u: pkgs.writeText "timekpr.${username}.conf" (renderUserConf username u))
        cfg.users;

      shippedConf = "${pkgs.timekpr}/etc/timekpr/timekpr.conf";
      extraExcl = lib.concatStringsSep ";" cfg.excludeUsers;

      mainConf =
        if cfg.excludeUsers == [ ] then shippedConf
        else
          pkgs.runCommand "timekpr.conf" { } ''
            sed -E 's|^(TIMEKPR_USERS_EXCL[[:space:]]*=[[:space:]]*.*)$|\1;${extraExcl}|' \
              ${shippedConf} > $out
            grep -qE '^TIMEKPR_USERS_EXCL[[:space:]]*=.*;${extraExcl}$' $out || {
              echo "timekpr: TIMEKPR_USERS_EXCL not found in ${shippedConf};" >&2
              echo "upstream must have renamed it — refusing to ship a config" >&2
              echo "that silently drops excludeUsers = ${extraExcl}" >&2
              exit 1
            }
          '';

      # Re-seed a user's config whenever the DECLARED policy changes, and
      # never otherwise.
      #
      # This replaces a tmpfiles `C` rule, which was "copy only if the
      # destination is missing". That was wrong in the one way that
      # mattered: it made a policy change in this flake a silent no-op on
      # every host that had already booted once. Editing the budget here
      # and rebuilding did nothing at all, forever, with no error.
      #
      # The stamp holds the store path of the seed that was last applied.
      # Different path => the declaration changed => overwrite. Same path
      # => leave the file alone, so runtime `timekpra` adjustments and the
      # daemon's own rewrites still persist across reboots.
      seedScript = pkgs.writeShellApplication {
        name = "timekpr-seed-config";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          install -d -m 0755 /var/lib/timekpr /var/lib/timekpr/config /var/lib/timekpr/work
        '' + lib.concatStrings (lib.mapAttrsToList
          (username: seedFile: ''
            conf=/var/lib/timekpr/config/timekpr.${username}.conf
            stamp=/var/lib/timekpr/config/.seed-${username}
            if [ ! -e "$conf" ] || [ "$(cat "$stamp" 2>/dev/null || true)" != "${seedFile}" ]; then
              install -m 0644 -o root -g root ${seedFile} "$conf"
              printf '%s' "${seedFile}" > "$stamp"
              echo "timekpr-seed: applied declared config for ${username}"
            fi
          '')
          userSeedFiles);
      };
    in
    {
      options.timekpr = {
        users = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule userOpts);
          default = { };
          description = ''
            Per-user time policies. The attribute name is the unix
            username; the value declares that user's curfew window and
            daily budget.

            Users not listed here are NOT automatically ignored — see
            `excludeUsers`. timekpr tracks every non-system user that
            logs in and auto-creates an unrestricted config for anyone
            it has never seen.
          '';
        };

        excludeUsers = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "p" ];
          description = ''
            Usernames appended to timekpr's `TIMEKPR_USERS_EXCL`, on top
            of the login managers upstream already excludes.

            This matters for admin accounts. The daemon enrolls every
            valid non-excluded user that logs in
            (`server/interface/dbus/daemon.py`) and calls
            `initUserConfiguration()` for unknown ones, writing an
            unrestricted config. So an unlisted admin is not *limited*,
            but it is *tracked*: it gets the timekpr tray icon and
            notifications on the kids' machines, and a single mis-click
            in the timekpra admin GUI can lock the admin out of the very
            box needed to undo it. Listing the admin here removes it
            from timekpr's view entirely.
          '';
        };
      };

      config = {
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
        # patched to the nix store. When `excludeUsers` is empty we
        # symlink it verbatim; otherwise we append to its
        # TIMEKPR_USERS_EXCL line and ship the result.
        #
        # Patching by sed rather than rewriting the file wholesale keeps
        # every other upstream key (and any key a future release adds)
        # exactly as shipped. That matters more than usual here: this
        # file lives in the read-only store, and if the daemon fails to
        # read any expected key it calls initTimekprConfig() and tries to
        # write the file back. The `grep -q` is a build-time guard so an
        # upstream rename of TIMEKPR_USERS_EXCL fails the build instead
        # of silently dropping the exclusion.
        environment.etc."timekpr/timekpr.conf".source = mainConf;

        # Logrotate snippet shipped by upstream (rotates /var/log/timekpr*).
        environment.etc."logrotate.d/timekpr".source =
          "${pkgs.timekpr}/etc/logrotate.d/timekpr";

        # Seed per-user config files. The actual copy is done by
        # timekpr-seed-config.service below (tmpfiles `C` could not express
        # "re-copy when the declaration changes"); these rules only
        # guarantee the directories exist for anything else that looks.
        systemd.tmpfiles.rules = [
          "d /var/lib/timekpr 0755 root root -"
          "d /var/lib/timekpr/config 0755 root root -"
          "d /var/lib/timekpr/work 0755 root root -"
        ];

        # Must land before the daemon reads the config, and must re-run on a
        # switch that changes the seed — hence both the ordering and the
        # restartTriggers. Without the trigger a `nixos-rebuild switch` would
        # write the new seed only at the next reboot.
        systemd.services.timekpr-seed-config = {
          description = "Apply declared timekpr per-user configuration";
          wantedBy = [ "multi-user.target" ];
          before = [ "timekpr.service" ];
          restartTriggers = lib.attrValues userSeedFiles;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe seedScript;
          };
        };

        # The daemon. The unit shipped at
        # ${pkgs.timekpr}/lib/systemd/system/timekpr.service uses
        # absolute store paths for ExecStart and WorkingDirectory, so
        # we just adopt it wholesale by listing the package as a
        # systemd package and enabling the unit.
        systemd.packages = [ pkgs.timekpr ];
        systemd.services.timekpr = {
          wantedBy = [ "multi-user.target" ];
          # Without this the daemon keeps serving whatever policy it parsed
          # at boot, and a switch that changes the budget looks like a no-op
          # until the next reboot.
          restartTriggers = lib.attrValues userSeedFiles;
        };
      };
    };
}
