# crowdsec.nix — CrowdSec IPS for the homelab edge.
#
# Why this exists:
#   Layer-7 intrusion prevention at the reverse proxy: CrowdSec parses
#   access logs, detects scans/brute-force/web attacks, and a bouncer
#   blocks bad IPs (community blocklists included). This is the evolution
#   of the current apphost crowdsec. Runs natively alongside the native
#   Caddy edge.
#
# This module just gates the daemon on. Acquisitions (which logs to parse)
# + the Caddy bouncer wiring + enrollment land in P1 when the edge is
# assembled in the DMZ microvm; keeping them out here avoids baking
# host-specifics into the primitive.
#
# Inert until `homelab.crowdsec.enable = true`.
#
# Retire when: the homelab swaps IPS, or CrowdSec is folded into a broader
#   edge module.
{ ... }:
{
  flake.modules.nixos.crowdsec = { config, lib, ... }:
    let
      cfg = config.homelab.crowdsec;
    in
    {
      options.homelab.crowdsec.enable =
        lib.mkEnableOption "CrowdSec IPS daemon";

      config = lib.mkIf cfg.enable {
        services.crowdsec.enable = true;
      };
    };
}
