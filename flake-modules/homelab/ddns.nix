# ddns.nix — Cloudflare dynamic-DNS updater for the homelab public IP.
#
# Why this exists:
#   Public exposure is via port-forward at the OpenWRT gateway (not a
#   tunnel), so the home IP must be kept current in Cloudflare DNS. This
#   wires services.cloudflare-dyndns, reading the API token from an
#   out-of-store secret file (`config.homelab.secrets.dir/cloudflare-token`).
#
# immich uses a DNS-only (grey-cloud) record so large uploads bypass
# Cloudflare's 100 MB proxy cap → set `proxied = false` for it upstream;
# other records may be proxied. This module manages the A-record IP; the
# grey/orange choice is per-record in the Cloudflare dashboard.
#
# Inert until `homelab.ddns.cloudflare = true`.
#
# Retire when: exposure moves to a tunnel (no port-forward → no DDNS), or
#   the IP becomes static.
{ ... }:
{
  flake.modules.nixos.ddns = { config, lib, ... }:
    let
      cfg = config.homelab.ddns;
    in
    {
      options.homelab.ddns = {
        cloudflare = lib.mkEnableOption "Cloudflare DDNS (home IP → DNS)";
        domains = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "home.example.com" ];
          description = "FQDNs to point at the current public IP.";
        };
        proxied = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Cloudflare proxy (orange). false = DNS-only (grey).";
        };
      };

      config = lib.mkIf cfg.cloudflare {
        services.cloudflare-dyndns = {
          enable = true;
          apiTokenFile = "${config.homelab.secrets.dir}/cloudflare-token";
          domains = cfg.domains;
          proxied = cfg.proxied;
        };
      };
    };
}
