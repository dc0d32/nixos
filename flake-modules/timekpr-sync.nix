# timekpr-sync — the per-host half of the shared cross-host screen-time
# budget. Reports this machine's locally-consumed seconds to the
# controller (flake-modules/timekpr-central.nix) and applies the shared
# remainder back through `timekpra`, so a kid with accounts on two
# machines gets ONE budget per day instead of one per machine.
#
# Enforcement stays entirely local: this agent only moves a number. If the
# controller is down or the laptop is off the LAN, the agent no-ops and
# the host falls back to its own local per-host cap. Degraded, never
# unenforced, and never locking anyone out because a server is missing.
#
# Pattern A: imported by hosts that run kid accounts (pb-t480, m-pc).
#
# HISTORY — two real bugs this rewrite fixes:
#
#  1. The old shell agent read `<workdir>/timekpr.<user>.time`. Upstream
#     names it `<workdir>/<user>.time` (timekpr common/utils/config.py:
#     `os.path.join(pDirectory, "%s.time" % (pUserName))`). The `[ -f ]`
#     guard turned that into a silent no-op, so the shared budget never
#     actually worked on any host.
#
#  2. `options.timekpr-sync` was declared at the flake-parts TOP level
#     while both host bridges set `timekpr-sync.serverUrl`. Those are the
#     SAME option — it only ever evaluated because `types.str` merges
#     equal definitions and the two hosts happened to set byte-identical
#     values. Changing one host's server URL would have failed the whole
#     flake with a merge conflict. Options now live inside the NixOS
#     module, where each host gets its own instance.
#
#  3. It also re-applied `--settimeleft` unconditionally every 60s. Each
#     write touches the control file, the daemon reloads and fires
#     timeLeftChangedNotification — a tray popup for the kid, once a
#     minute, forever. The agent now writes only past a tolerance.
#
# Retire when: timekpr-nExT grows native multi-host accounting, OR the
#   household stops needing a shared budget (see timekpr-central.nix).
{ ... }:
{
  flake.modules.nixos.timekpr-sync = { lib, config, pkgs, ... }:
    let
      cfg = config.timekpr-sync;

      spec = pkgs.writeText "timekpr-sync.json" (builtins.toJSON {
        inherit (cfg) serverUrl users maxExtraMinutes toleranceSeconds token tokenFile;
        hostName = config.networking.hostName;
        workDir = "/var/lib/timekpr/work";
        configDir = "/var/lib/timekpr/config";
        timekpra = "${pkgs.timekpr}/bin/timekpra";
        loginctl = "${pkgs.systemd}/bin/loginctl";
        timeout = 8;
      });
    in
    {
      options.timekpr-sync = {
        serverUrl = lib.mkOption {
          type = lib.types.str;
          default = "";
          example = "https://screentime.bitset.cc";
          description = ''
            Base URL of the timekpr-central controller. Empty disables the
            agent entirely (the host keeps its local per-host cap).

            Use the public hostname rather than the LAN IP. AdGuard rewrites
            *.bitset.cc to the DMZ edge for on-LAN clients, so the name works
            from any VLAN, survives ursa being renumbered, and — because the
            edge holds a real wildcard certificate — gives the agent a TLS
            channel it can actually authenticate. That matters: over plain
            HTTP to an IP, anyone able to ARP-spoof the LAN could forge a
            reply and hand out `maxExtraMinutes` of free time.

            Off-LAN the name resolves publicly, the edge's LAN guard answers
            403, and the agent no-ops — the host then enforces its own local
            cap, which is the intended degradation.
          '';
        };
        users = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "m" "s" ];
          description = ''
            Kid usernames to keep in shared-budget sync. A user with no
            work file on this host (never logged in here) is skipped.
          '';
        };
        maxExtraMinutes = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 60;
          description = ''
            Headroom the agent will accept ABOVE this host's own local cap
            for today. The clamp is the defense against a spoofed
            controller on a hostile network: the worst a fake server can do
            is hand out today's local limit plus this much, instead of an
            unbounded day. Set to 0 to make the local cap a hard ceiling —
            at the cost of parent-granted bonus time not landing on hosts
            whose local budget is already spent.
          '';
        };
        toleranceSeconds = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 60;
          description = ''
            Only write back when the shared remainder differs from what
            local enforcement already believes by more than this. Every
            write makes the daemon reload and raise a "time left changed"
            tray notification, so a tolerance below the poll interval just
            spams the user.
          '';
        };
        token = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            Shared bearer token sent on POST /report. Must match the
            controller's `token`/`tokenFile`.

            This one is fine to keep in git — see the note on
            `flake.lib.timekprCentral` in flake-modules/kid-hm.nix. It
            only authorizes "report usage", and usage is stored
            monotonically, so it can never buy anyone time. It also ends
            up world-readable in /nix/store regardless.
          '';
        };
        tokenFile = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          example = "/persist/secrets/timekpr-token";
          description = ''
            Read the token from this file instead of `token`. Wins over
            `token` when set. Only worth the provisioning cost if the
            report endpoint is ever given an operation that can GRANT
            time; today it cannot.
          '';
        };
        interval = lib.mkOption {
          type = lib.types.str;
          default = "1m";
          description = "How often to reconcile with the controller.";
        };
      };

      config = lib.mkIf (cfg.serverUrl != "" && cfg.users != [ ]) {
        systemd.services.timekpr-sync = {
          description = "Reconcile local timekpr usage with the shared budget";
          after = [ "timekpr.service" "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart =
              "${pkgs.python3}/bin/python3 ${./timekpr-sync.py} ${spec}";
            # Root: `timekpra`'s admin D-Bus interface is restricted to the
            # timekpr group by upstream policy, and the work/config files
            # under /var/lib/timekpr are root-owned.
            ProtectSystem = "strict";
            ReadWritePaths = [ "/var/lib/timekpr" ];
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
          };
        };

        systemd.timers.timekpr-sync = {
          description = "Periodic shared-budget reconciliation";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "1m";
            OnUnitActiveSec = cfg.interval;
            # A laptop that suspends through a tick should reconcile on
            # wake rather than waiting out a full interval — the kid may
            # have burned budget on the other machine meanwhile.
            Persistent = true;
          };
        };
      };
    };
}
