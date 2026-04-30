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
#                                      lockoutType; trackInactive; }; ... };
#
# `allowedHours` is an "HH:MM-HH:MM" string per day, applied to all
# seven weekdays uniformly (kids' schedules don't usually vary by day).
# Minutes inside the hour are ignored by timekpr's hour-grain accounting
# but the string is the most readable input format. We translate to
# timekpr's `ALLOWED_HOURS_<1-7> = h;h;h;...` semicolon list at render
# time.
#
# `dailyBudgetMinutes` is the per-day usage budget; rendered into
# `LIMITS_PER_WEEKDAYS` as seven identical seconds values.
#
# Per-user files are seeded into /var/lib/timekpr/config/timekpr.<user>.conf
# via systemd.tmpfiles `C` (copy-if-missing) rules so the daemon's own
# rewrites (when admin uses the GUI/CLI to adjust limits at runtime)
# survive across reboots. To re-apply the declared defaults, delete
# /var/lib/timekpr/config/timekpr.<user>.conf and rebuild.
#
# Retire when: NixOS upstream grows a `services.timekpr` module (none
# at time of writing — only `services.timekpr-next` exists in flake-
# parts hearsay; nixpkgs HEAD ships no such thing), OR when this
# household stops needing parental controls.
{ lib, config, ... }:
let
  cfg = config.timekpr;

  # Per-user config submodule.
  userOpts = { name, ... }: {
    options = {
      allowedHours = lib.mkOption {
        type = lib.types.str;
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
        '';
      };
      dailyBudgetMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        example = 240;
        description = ''
          Total daily usage budget in minutes, applied uniformly across
          all seven weekdays. Independent of `allowedHours` — the user
          is allowed to log in only during the window AND only for this
          much accumulated time per day, whichever runs out first.
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

  # Render an "HH:MM-HH:MM" string into a semicolon-separated list of
  # allowed hour numbers (start inclusive, end exclusive) suitable for
  # ALLOWED_HOURS_<n>.
  renderAllowedHours = window:
    let
      m = builtins.match "([0-9]+):([0-9]+)-([0-9]+):([0-9]+)" window;
      _ = if m == null
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
      _check = if startH < 0 || startH > 23 || endH < 0 || endH > 24 || startH >= endH
        then throw "timekpr: allowedHours invalid range: ${window}"
        else null;
      hours = lib.range startH (endH - 1);
    in
    lib.concatStringsSep ";" (map toString hours);

  # Render a per-user config file body.
  renderUserConf = username: u: ''
    [DOCUMENTATION]
    #### managed by flake-modules/timekpr.nix — initial seed only.
    #### the daemon may rewrite this file when admin uses timekpra/timekprc
    #### at runtime. delete the file and rebuild to re-apply declared defaults.

    [USER]
    ALLOWED_HOURS_1 = ${renderAllowedHours u.allowedHours}
    ALLOWED_HOURS_2 = ${renderAllowedHours u.allowedHours}
    ALLOWED_HOURS_3 = ${renderAllowedHours u.allowedHours}
    ALLOWED_HOURS_4 = ${renderAllowedHours u.allowedHours}
    ALLOWED_HOURS_5 = ${renderAllowedHours u.allowedHours}
    ALLOWED_HOURS_6 = ${renderAllowedHours u.allowedHours}
    ALLOWED_HOURS_7 = ${renderAllowedHours u.allowedHours}
    ALLOWED_WEEKDAYS = 1;2;3;4;5;6;7
    LIMITS_PER_WEEKDAYS = ${
      lib.concatStringsSep ";" (lib.genList (_: toString (u.dailyBudgetMinutes * 60)) 7)
    }
    LIMIT_PER_WEEK = ${toString (u.dailyBudgetMinutes * 60 * 7)}
    LIMIT_PER_MONTH = ${toString (u.dailyBudgetMinutes * 60 * 31)}
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
