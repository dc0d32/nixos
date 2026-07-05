# caddy.nix — native (non-container) reverse proxy for homelab hosts,
# with systemd hardening.
#
# Why native, not a docker container:
#   The edge/ingress is host *infrastructure*, not an app. Running it as a
#   native NixOS service lets its config be generated from declarative
#   metadata, keeps ingress + TLS up independent of the docker daemon, and
#   lets it run as a hardened, unprivileged systemd unit. (Apps stay as
#   docker-compose stacks; Caddy proxies to their published ports.)
#
# What this module does TODAY (P0 baseline):
#   * opens 80/443 when `services.caddy.enable` is set, and
#   * layers extra systemd sandboxing onto the caddy unit.
#   Enabling Caddy and declaring vhosts is left to the host for now
#   (`services.caddy.enable` + `services.caddy.virtualHosts`).
#
# What lands later (P1):
#   * build Caddy `withPlugins` (caddy-dns/cloudflare for Let's Encrypt
#     DNS-01 wildcard certs, caddy-crowdsec-bouncer),
#   * generate the Caddyfile from the stack registry's expose metadata
#     (`none|lan|public` + authentik forward-auth), and
#   * the internet-facing instance moves into the DMZ microvm.
#
# Retire when:
#   * The edge moves to a different proxy, OR
#   * Orchestration (Nomad) fronts services via its own ingress and this
#     static Caddy layer is no longer the front door.
{ ... }:
{
  flake.modules.nixos.caddy = { config, lib, ... }:
    lib.mkIf config.services.caddy.enable {
      networking.firewall.allowedTCPPorts = [ 80 443 ];

      # Additive hardening on top of what nixpkgs' services.caddy already
      # sets (it runs as the unprivileged `caddy` user with
      # CAP_NET_BIND_SERVICE). These are safe for a static Go binary.
      systemd.services.caddy.serviceConfig = {
        NoNewPrivileges = true;
        LockPersonality = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };
}
