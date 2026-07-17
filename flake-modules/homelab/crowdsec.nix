# crowdsec.nix — CrowdSec IPS for the homelab edge (native, log-driven).
#
# Why this exists:
#   Layer-7 intrusion prevention at the reverse proxy: CrowdSec parses Caddy
#   access logs, detects scans/brute-force/web attacks, and a firewall bouncer
#   drops bad IPs at the host's own nftables/iptables INPUT chain. This protects
#   the DIRECT-to-origin path especially — an attacker who hits the origin IP
#   (bypassing Cloudflare) arrives with their real source IP, which the bouncer
#   bans at L3. (CF-proxied traffic arrives from CF IPs; enforcing on those needs
#   a Cloudflare bouncer — a follow-up — so we only whitelist CF infra here.)
#
# Importing IS enabling-capable: set `homelab.crowdsec.enable = true` on any host
# that runs the edge Caddy (the guest microvm AND, transitionally, the ursa
# host). All the wiring below is shared so both get an identical IPS.
#
# THE key fix (why this used to be broken):
#   The nixpkgs crowdsec + firewall-bouncer modules run every unit under
#   DynamicUser=yes, which sandboxes /var/lib/crowdsec into each unit's private
#   mount namespace. cscli invoked by a *separate* unit (the bouncer registrar)
#   or by hand then can't stat the state dir, and go-cs-lib trace.Init
#   (os.MkdirAll) misreports "mkdir /var/lib/crowdsec: file exists" — breaking
#   ALL cscli management (incl. bouncer registration). Forcing DynamicUser off
#   (the module already declares a static `crowdsec` system user) puts state in a
#   normally-owned /var/lib/crowdsec every unit + cscli can traverse. This is a
#   NixOS-module interaction, NOT a crowdsec version bug (MkdirAll tolerates
#   EEXIST). See homelab/sessions/2026-07-12-crowdsec-fix-and-cert-incident.md.
#
# Retire when:
#   * The edge moves to a different proxy/IPS, OR
#   * Enforcement folds into a Cloudflare bouncer + this native layer is dropped.
{ ... }:
{
  flake.modules.nixos.crowdsec = { config, lib, ... }:
    let
      cfg = config.homelab.crowdsec;
      hasCaddy = config.services.caddy.enable;
      # Cloudflare edge ranges (https://www.cloudflare.com/ips — refresh if CF
      # publishes new ones). Caddy trusts them as proxies (recover the real
      # client from X-Forwarded-For / Cf-Connecting-Ip) and crowdsec whitelists
      # them (never ban CF infra -> no self-inflicted outage).
      cloudflareRanges = [
        "173.245.48.0/20"
        "103.21.244.0/22"
        "103.22.200.0/22"
        "103.31.4.0/22"
        "141.101.64.0/18"
        "108.162.192.0/18"
        "190.93.240.0/20"
        "188.114.96.0/20"
        "197.234.240.0/22"
        "198.41.128.0/17"
        "162.158.0.0/15"
        "104.16.0.0/13"
        "104.24.0.0/14"
        "172.64.0.0/13"
        "131.0.72.0/22"
        "2400:cb00::/32"
        "2606:4700::/32"
        "2803:f800::/32"
        "2405:b500::/32"
        "2405:8100::/32"
        "2a06:98c0::/29"
        "2c0f:f248::/32"
      ];
    in
    {
      options.homelab.crowdsec.enable =
        lib.mkEnableOption "CrowdSec IPS (agent + local API + firewall bouncer)";

      config = lib.mkIf cfg.enable (lib.mkMerge [
        {
          services.crowdsec.enable = true;

          # --- the DynamicUser fix (see header) --------------------------
          systemd.services.crowdsec.serviceConfig.DynamicUser = lib.mkForce false;
          systemd.services.crowdsec-firewall-bouncer.serviceConfig.DynamicUser = lib.mkForce false;
          systemd.services.crowdsec-firewall-bouncer-register.serviceConfig.DynamicUser = lib.mkForce false;
          # The bouncer main unit doesn't order itself after the registrar that
          # writes its API key -> on a cold boot it can start first and fail
          # (243/CREDENTIALS). Make the dependency explicit.
          systemd.services.crowdsec-firewall-bouncer = {
            after = [ "crowdsec-firewall-bouncer-register.service" ];
            requires = [ "crowdsec-firewall-bouncer-register.service" ];
          };

          services.crowdsec = {
            # Standalone edge: agent + LAPI + bouncer on one box. Without the
            # local API server the module never bootstraps the machine creds and
            # the agent fatals "no API client section".
            settings.general.api.server.enable = true;
            settings.lapi.credentialsFile =
              "/var/lib/crowdsec/state/local_api_credentials.yaml";
            hub = {
              # crowdsecurity/caddy => Caddy JSON parser + base-http scenarios;
              # http-cve => known-exploit detection.
              collections = [ "crowdsecurity/caddy" "crowdsecurity/http-cve" ];
              # syslog-logs ships the s00 `non-syslog` raw parser that populates
              # evt.Parsed.message/program for FILE datasources — without it the
              # caddy-logs filter never matches (every line "unparsed").
              # whitelists => never ban RFC1918 (LAN clients).
              parsers = [ "crowdsecurity/syslog-logs" "crowdsecurity/whitelists" ];
            };
            localConfig = {
              acquisitions = [{
                source = "file";
                filenames = [ "/var/log/caddy/access-*.log" ];
                labels.type = "caddy";
              }];
              # Never ban a Cloudflare edge IP (would cut off a whole CF PoP).
              parsers.s02Enrich = [{
                name = "edge/cloudflare-whitelist";
                description = "Never ban Cloudflare edge IPs";
                whitelist = {
                  reason = "cloudflare edge ranges (CF infra, not the attacker)";
                  cidr = cloudflareRanges;
                };
              }];
            };
          };

          services.crowdsec-firewall-bouncer.enable = true;
          # The upstream registrar runs RAW cscli (no -c), which reads
          # /etc/crowdsec/config.yaml; the module only feeds the daemon a
          # store-path config. Materialise the same settings there (crowdsec/cscli
          # read YAML; JSON is valid YAML).
          environment.etc."crowdsec/config.yaml".text =
            builtins.toJSON config.services.crowdsec.settings.general;
        }

        # --- Caddy-side wiring (only where the edge Caddy runs) -----------
        (lib.mkIf hasCaddy {
          # crowdsec tails Caddy's access logs; Caddy's file logger is 0600, so
          # the stacks module writes them 0640 and crowdsec joins the caddy group.
          users.users.crowdsec.extraGroups = [ "caddy" ];
          # Trust Cloudflare as a proxy so Caddy recovers the real client IP.
          # (types.lines — concatenates with any other globalConfig.)
          services.caddy.globalConfig = ''
            servers {
              trusted_proxies static ${lib.concatStringsSep " " cloudflareRanges}
              client_ip_headers Cf-Connecting-Ip X-Forwarded-For
            }
          '';
        })
      ]);
    };
}
