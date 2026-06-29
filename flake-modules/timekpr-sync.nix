# Timekpr cross-host sync agent. Reports each kid's locally-consumed time
# to the central control plane on the docker host and applies the shared
# remaining back via timekpra, so m/s get ONE daily budget across pb-t480
# + m-pc instead of one per machine. Enforcement stays local timekpr, so
# an off-LAN laptop just keeps its local cap.
#
# Pattern A: imported by hosts that run kid accounts (pb-t480, m-pc).
# Option scoping mirrors flake-modules/timekpr.nix: `options.timekpr-sync`
# is declared at the flake-parts top level and the agent reads it from the
# OUTER `config` (let-bound `cfg`). Hosts set timekpr-sync.{serverUrl,users}
# at the bridge top level alongside timekpr.users. lib.unique guards the
# loop so the shared serverUrl + merged user list stay harmless (a host
# without a given kid's work file simply skips it).
{ lib, config, ... }:
let cfg = config.timekpr-sync; in
{
  options.timekpr-sync = {
    serverUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "http://nas:8780";
      description = "Base URL of the timekpr-central control plane (LAN).";
    };
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "m" "s" ];
      description = "Kid usernames to keep in shared-budget sync.";
    };
  };

  config.flake.modules.nixos.timekpr-sync = { pkgs, ... }:
    let
      agent = pkgs.writeShellApplication {
        name = "timekpr-sync";
        runtimeInputs = [ pkgs.timekpr pkgs.curl pkgs.gnugrep pkgs.gawk pkgs.coreutils ];
        text = ''
          host=$(hostname)
          for u in ${lib.escapeShellArgs (lib.unique cfg.users)}; do
            work=/var/lib/timekpr/work/timekpr.$u.time
            [ -f "$work" ] || continue
            # Positive used-seconds today; remaining is set absolutely below.
            consumed=$(grep -E '^TIME_SPENT_DAY' "$work" | awk -F= '{gsub(/ /,"",$2);print $2}')
            [ -n "$consumed" ] || consumed=0
            resp=$(curl -fsS --max-time 8 -XPOST "${cfg.serverUrl}/report" \
              -d "host=$host" -d "user=$u" -d "consumed=$consumed" 2>/dev/null) || continue
            rem=$(echo "$resp" | grep -oE '"remaining":[0-9]+' | grep -oE '[0-9]+')
            [ -n "$rem" ] || continue
            # "=" sets remaining absolutely ("+"/"-" add/subtract). Root is
            # allowed the timekpr admin D-Bus interface by upstream policy.
            timekpra --settimeleft "$u" = "$rem" >/dev/null 2>&1 || true
          done
        '';
      };
    in
    {
      systemd.services.timekpr-sync = {
        description = "Sync timekpr usage with the shared-budget control plane";
        after = [ "timekpr.service" "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = { Type = "oneshot"; ExecStart = lib.getExe agent; };
      };
      systemd.timers.timekpr-sync = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "1m"; OnUnitActiveSec = "1m"; };
      };
    };
}
