# timekpr-central — one shared screen-time budget across several hosts.
#
# Why this exists:
#   flake-modules/timekpr.nix enforces a daily budget PER HOST. A kid with
#   accounts on two machines therefore gets the budget twice: spend four
#   hours on the laptop, walk to the desktop, spend four more. This module
#   is the accounting authority that closes that hole. Each kid host runs
#   flake-modules/timekpr-sync.nix, which reports locally-consumed seconds
#   here and applies the shared remaining back through `timekpra`.
#
#   Enforcement deliberately stays local. This service never terminates a
#   session; it only publishes a number. If it is down, or the laptop is
#   off the LAN, the agent no-ops and the host falls back to its own local
#   cap — degraded (the budget is per-host again) but never unenforced,
#   and never locking a kid out because a server is unreachable.
#
# Anti-tamper:
#   Usage is stored monotonically per (host, user, day): a report can only
#   ever raise the stored value. Forging a LOW report cannot rewind the
#   counter, and forging a HIGH one only costs the forger their own time.
#   That property — not the optional bearer token — is what makes this
#   safe to run on a LAN the kids' own machines sit on.
#
# Pattern A: importing IS enabling. Imported by the host that plays
# controller (ursa, in the private homelab flake). Inert until
# `timekpr-central.users` is set, so it can also be imported purely to
# eval-validate it.
#
# Options are declared INSIDE the NixOS module rather than at the
# flake-parts top level. That is mandatory here: the private homelab flake
# consumes this as an already-evaluated `pub.modules.nixos.timekpr-central`
# attribute and can only set options that exist in NixOS module scope.
# (It is also what flake-modules/timekpr-sync.nix got wrong — see its
# header.) Precedent: flake-modules/homelab/node-exporter.nix.
#
# Secrets are plain files on the host, per the repo's no-secrets-framework
# rule (see flake-modules/homelab/secrets.nix): `adminPasswordFile` gates
# the dashboard, optional `tokenFile` gates /report.
#
# The dashboard shows a week x 24h calendar of the allowed window
# alongside the budget. Those are two INDEPENDENT axes in timekpr — the
# daemon takes min(budget left, hour limits), so granting time can never
# open a blocked hour — and a dashboard showing only the budget is
# therefore actively misleading: "4h 59m left" at 23:35 is true and
# unusable at the same time. `allowedHoursByDay` is fed in for display
# only; this service still never enforces anything.
#
# Retire when: timekpr-nExT grows native multi-host accounting (upstream
#   has no such feature and no issue tracking one), OR the household stops
#   needing a shared budget (one host per kid, or the kids age out).
{ ... }:
{
  flake.modules.nixos.timekpr-central = { lib, config, pkgs, ... }:
    let
      cfg = config.timekpr-central;

      spec = pkgs.writeText "timekpr-central.json" (builtins.toJSON {
        inherit (cfg) port stateDir bind adminUser;
        adminPasswordFile = cfg.adminPasswordFile;
        token = cfg.token;
        tokenFile = cfg.tokenFile;
        users = lib.mapAttrs
          (_: u: { inherit (u) budgetMinutesByDay allowedHoursByDay; })
          cfg.users;
      });
    in
    {
      options.timekpr-central = {
        users = lib.mkOption {
          default = { };
          description = ''
            Users tracked by the shared budget, keyed by unix username.
            Budgets should be single-sourced from the same policy the kid
            hosts render into their local timekpr config, so the controller
            and the laptops cannot drift — on ursa that means feeding
            `pub.lib.kidTimekprPolicy.dailyBudgetMinutesByDay` in here.
          '';
          example = lib.literalExpression ''
            {
              m = {
                budgetMinutesByDay = {
                  mon = 240; tue = 240; wed = 240; thu = 240;
                  fri = 240; sat = 360; sun = 360;
                };
                allowedHoursByDay = {
                  mon = "06:00-22:00"; tue = "06:00-22:00";
                  wed = "06:00-22:00"; thu = "06:00-22:00";
                  fri = "06:00-23:00"; sat = "06:00-23:00";
                  sun = "06:00-22:00";
                };
              };
            }
          '';
          type = lib.types.attrsOf (lib.types.submodule {
            options.budgetMinutesByDay = lib.mkOption {
              description = ''
                Shared daily budget in minutes, per weekday. All seven days
                must be given; a missing day is a build-time error rather
                than a silent zero.
              '';
              type = lib.types.submodule {
                options = lib.genAttrs
                  [ "mon" "tue" "wed" "thu" "fri" "sat" "sun" ]
                  (_: lib.mkOption { type = lib.types.ints.positive; });
              };
            };

            # Display only — the controller never enforces the window. The
            # kid's own timekpr daemon already does, and it is the only thing
            # that can (it is the one watching the session). This exists so
            # the dashboard can SHOW the curfew: without it a parent sees
            # "4h 59m left" at 23:35 and reasonably concludes the system is
            # broken, when in fact the daily window closed at 22:00 and
            # timekpr is locking correctly. Budget and window are independent
            # axes and a grant cannot open a blocked hour, so a dashboard
            # that shows only the budget is actively misleading.
            options.allowedHoursByDay = lib.mkOption {
              default = null;
              description = ''
                Per-weekday allowed window as "HH:MM-HH:MM", start inclusive
                and end EXCLUSIVE at hour grain — "06:00-22:00" permits
                06:00..21:59. Must match the `allowedHoursByDay` the kid
                hosts render into their local timekpr config, so single-source
                both from the same policy attrset (on ursa that is
                `pub.lib.kidTimekprPolicy`).

                Optional, unlike the budget: the controller cannot enforce a
                window and the dashboard simply omits the calendar when this
                is null, so requiring it would break existing deployments to
                buy nothing. But if you DO give it, all seven days are
                required — a half-specified week would draw a calendar that
                lies about the days it omits, which is worse than no calendar.
              '';
              example = lib.literalExpression ''
                {
                  mon = "06:00-22:00"; tue = "06:00-22:00"; wed = "06:00-22:00";
                  thu = "06:00-22:00"; fri = "06:00-23:00"; sat = "06:00-23:00";
                  sun = "06:00-22:00";
                }
              '';
              type = lib.types.nullOr (lib.types.submodule {
                options = lib.genAttrs
                  [ "mon" "tue" "wed" "thu" "fri" "sat" "sun" ]
                  (_: lib.mkOption { type = lib.types.strMatching "[0-9]{1,2}:[0-9]{2}-[0-9]{1,2}:[0-9]{2}"; });
              });
            };
          });
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 8780;
          description = "TCP port the controller listens on.";
        };

        bind = lib.mkOption {
          type = lib.types.str;
          default = "0.0.0.0";
          description = ''
            Listen address. Left wide by default and scoped with
            `allowedInterfaces` at the firewall instead, so a host with
            several VLANs does not need the address hard-coded here.
          '';
        };

        stateDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/timekpr-central";
          description = ''
            Holds usage.db. Persist this on an impermanence host, or every
            reboot of the CONTROLLER hands every kid a fresh budget.
          '';
        };

        allowedInterfaces = lib.mkOption {
          type = with lib.types; nullOr (listOf str);
          default = null;
          example = [ "vlan10" ];
          description = ''
            Interfaces the port is reachable on. `null` opens it on every
            interface; a list scopes it to just those (e.g. the trusted
            VLAN the kid hosts live on); `[ ]` keeps it fully firewalled.
          '';
        };

        adminUser = lib.mkOption {
          type = lib.types.str;
          default = "parent";
          description = "HTTP basic-auth username for the dashboard.";
        };

        adminPasswordFile = lib.mkOption {
          type = lib.types.str;
          default = "";
          example = "/persist/secrets/timekpr-dashboard.pass";
          description = ''
            File (mode 0600, root-owned) holding the dashboard password in
            plaintext. Read at startup, never copied into the nix store.
            The dashboard can grant time, and the kids' own machines are on
            this LAN, so the service fails CLOSED — every dashboard request
            is refused — while this file is missing or empty.
          '';
        };

        token = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            Shared bearer token required on `POST /report`. Empty means
            /report is unauthenticated, which is survivable because usage
            is stored monotonically (a report can only raise a counter),
            but setting it stops a bored kid — or a guest-VLAN device that
            can also reach the edge — from spamming inflated reports for a
            sibling.

            Safe to keep in git: it authorizes no operation that can grant
            time. See the note on `flake.lib.timekprCentral` in
            flake-modules/kid-hm.nix. The credential that DOES matter is
            `adminPasswordFile`, which must stay out of git.
          '';
        };

        tokenFile = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          example = "/persist/secrets/timekpr-token";
          description = ''
            Read the token from this file instead of `token`. Wins over
            `token` when set.
          '';
        };
      };

      config = {
        systemd.tmpfiles.rules = [
          "d ${cfg.stateDir} 0700 root root -"
        ];

        systemd.services.timekpr-central = {
          description = "Shared cross-host screen-time budget controller";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart =
              "${pkgs.python3}/bin/python3 ${./timekpr-central.py} ${spec}";
            Restart = "on-failure";
            RestartSec = "10s";
            # Runs as root only to read the 0600 secret files off /persist;
            # DynamicUser would not be able to. Everything else is clamped.
            # Same shape as homelab/nix/idrac-monitor.nix.
            ProtectSystem = "strict";
            ReadWritePaths = [ cfg.stateDir ];
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            NoNewPrivileges = true;
            RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
            SystemCallFilter = [ "@system-service" ];
          };
        };

        networking.firewall = lib.mkMerge [
          (lib.mkIf (cfg.allowedInterfaces == null) {
            allowedTCPPorts = [ cfg.port ];
          })
          (lib.mkIf (cfg.allowedInterfaces != null) {
            interfaces = lib.genAttrs cfg.allowedInterfaces
              (_: { allowedTCPPorts = [ cfg.port ]; });
          })
        ];
      };
    };
}
