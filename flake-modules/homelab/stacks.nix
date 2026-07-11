# stacks.nix — placement + expose engine for homelab docker stacks.
#
# Why this exists:
#   Turns the declarative registry (stacks-registry.nix) + a per-host
#   placement list into (1) a systemd `stack-<name>` oneshot that
#   `docker compose up -d`s each stack on this host, and (2) native Caddy
#   vhosts generated from each stack's expose metadata
#   (`none | lan | public`). Moving a service between nodes = move its line
#   between host bridges; making it public = flip `expose` (plus the
#   external port-forward + DNS record, which live at the gateway/Cloudflare).
#
# Compose stacks stay external files (existing repo decision); this only
# wires the OS around them. authentik forward-auth enforcement is added in
# P1 when the authentik endpoint exists.
#
# Inert until `homelab.stacks` is non-empty.
#
# Retire when: Nomad takes over scheduling (it would consume the registry
#   and this static compose-up/vhost generation goes away).
{ ... }:
{
  flake.modules.nixos.stacks = { config, lib, pkgs, ... }:
    let
      cfg = config.homelab.stacks;
      registry = config.homelab.registry;
      domain = config.homelab.domain;
      compose = "${pkgs.docker-compose}/bin/docker-compose";

      enabled = lib.filterAttrs (_: s: s.enable) cfg;
      # Only generate for stacks that actually have a registry entry; the
      # missing ones are reported by an assertion below (nicer than a raw
      # "attribute missing" eval error).
      valid = lib.filterAttrs (name: _: registry ? ${name}) enabled;
      resolve = name: s:
        let r = registry.${name};
        in {
          inherit (r) composeDir composeSrc subdomain upstream tlsUpstream;
          expose = if s.expose != null then s.expose else r.exposeDefault;
          auth = if s.auth != null then s.auth else r.authDefault;
        };
      resolved = lib.mapAttrs resolve valid;
      exposed = lib.filterAttrs (_: r: r.expose != "none") resolved;
      # composeDir → git-tracked compose file, for the dirs that have one.
      srcByDir = lib.listToAttrs (lib.filter (x: x.value != null)
        (lib.mapAttrsToList (_: r: lib.nameValuePair r.composeDir r.composeSrc) resolved));

      # Edge proxies: vhosts on THIS host that reverse-proxy to a REMOTE
      # upstream (a service still hosted elsewhere, pre-migration). Same Caddy
      # treatment as a local stack, but no compose unit. `resolve`-shaped so
      # they flow through mkVhostConfig unchanged.
      edgeResolved = lib.mapAttrs
        (_name: e: {
          inherit (e) subdomain upstream tlsUpstream expose auth;
          composeDir = null;
        })
        config.homelab.edgeProxies;
      edgeExposed = lib.filterAttrs (_: r: r.expose != "none") edgeResolved;

      # authentik outpost address (for forward_auth). Falls back to the
      # conventional local port if the SSO stack isn't in the registry.
      authikUpstream =
        if registry ? authentik then registry.authentik.upstream else "127.0.0.1:9000";

      # The upstream reverse_proxy directive — https + skip-verify for
      # self-signed HTTPS upstreams (code-server), plain http otherwise.
      proxyDirective = r:
        if r.tlsUpstream then ''
          reverse_proxy https://${r.upstream} {
            transport http {
              tls_insecure_skip_verify
            }
          }''
        else "reverse_proxy ${r.upstream}";

      # LAN-only guard: 403 anything whose source isn't an RFC1918 client.
      # Defense-in-depth behind the gateway (which simply doesn't
      # port-forward lan vhosts) — a misconfigured forward can't expose them.
      lanGuard = ''
        @external not remote_ip private_ranges
        respond @external "Forbidden (LAN only)" 403
      '';

      # authentik forward-auth (the P0-deferred enforcement). Passes the
      # outpost path straight through, then gates every other request on the
      # authentik Caddy outpost and copies the identity headers upstream.
      authBlock = ''
        reverse_proxy /outpost.goauthentik.io/* ${authikUpstream}
        forward_auth ${authikUpstream} {
          uri /outpost.goauthentik.io/auth/caddy
          copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Email X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt X-Authentik-Meta-Jwks X-Authentik-Meta-Outpost X-Authentik-Meta-Provider X-Authentik-Meta-App X-Authentik-Meta-Version
        }
      '';

      # Compose one vhost body. When a guard/auth step is present the whole
      # thing is wrapped in `route { }` so directives run in written order
      # (Caddy's default directive ordering would otherwise reshuffle the
      # two reverse_proxy blocks around forward_auth).
      mkVhostConfig = r:
        let
          parts =
            lib.optional (r.expose == "lan") lanGuard
            ++ lib.optional (r.auth == "authentik") authBlock
            ++ [ (proxyDirective r) ];
          body = lib.concatStringsSep "\n" parts;
        in
        if (r.expose == "lan") || (r.auth == "authentik")
        then "route {\n${body}\n}"
        else body;
    in
    {
      options.homelab.stacks = lib.mkOption {
        default = { };
        description = ''
          Registry stacks that run on THIS host (placement), with optional
          per-host overrides. Key must match a `homelab.registry` entry.
        '';
        example = { immich.expose = "public"; plex = { }; };
        type = lib.types.attrsOf (lib.types.submodule (_: {
          options = {
            enable = lib.mkOption { type = lib.types.bool; default = true; };
            expose = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum [ "none" "lan" "public" ]);
              default = null;
              description = "Override the registry exposeDefault.";
            };
            auth = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum [ "none" "authentik" "basic" ]);
              default = null;
            };
          };
        }));
      };

      options.homelab.edgeProxies = lib.mkOption {
        default = { };
        description = ''
          Temporary edge vhosts on THIS host that reverse-proxy a hostname to
          a REMOTE upstream — a service still hosted elsewhere (e.g. a not-yet-
          migrated Proxmox VM). Gets the same Caddy treatment as a local stack
          (lan-guard / authentik forward-auth / tlsUpstream) but has NO compose
          unit. Retire each entry once the service becomes a real
          `homelab.stacks` entry on its new host.
        '';
        example = {
          photos = { upstream = "192.168.10.10:2283"; expose = "public"; };
          home = { upstream = "192.168.10.2:8123"; expose = "public"; };
        };
        type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
          options = {
            subdomain = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "Subdomain under homelab.domain (defaults to the key).";
            };
            upstream = lib.mkOption {
              type = lib.types.str;
              example = "192.168.10.10:2283";
              description = "REMOTE host:port Caddy reverse-proxies to.";
            };
            expose = lib.mkOption {
              type = lib.types.enum [ "none" "lan" "public" ];
              default = "public";
            };
            auth = lib.mkOption {
              type = lib.types.enum [ "none" "authentik" "basic" ];
              default = "none";
            };
            tlsUpstream = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Upstream speaks HTTPS (proxy with https:// + skip-verify).";
            };
          };
        }));
      };

      config = lib.mkIf (enabled != { } || edgeExposed != { }) {
        assertions =
          (lib.mapAttrsToList
            (name: _: {
              assertion = registry ? ${name};
              message = "homelab.stacks.${name}: no matching homelab.registry.${name} entry.";
            })
            enabled)
          ++ [{
            assertion = (exposed == { } && edgeExposed == { }) -> (domain != "");
            message = "homelab.domain must be set when any stack or edge proxy is exposed.";
          }];

        # One compose-up oneshot per UNIQUE composeDir. Stacks that share a
        # compose project (e.g. cyberchef + it-tools live in the same dir)
        # must NOT get two units — two concurrent `docker compose up` on the
        # same project race on network/container creation and one fails
        # (observed in the ursa rehearsal: stack-it-tools failed while its
        # container was already up via stack-cyberchef). Keying by composeDir
        # collapses them to a single unit named after the dir; each stack
        # still gets its own vhost below.
        #
        # TimeoutStartSec is generous (30m): on a fresh host EVERY stack
        # pulls images at once and saturates the link — a 10m timeout tripped
        # several units in the rehearsal that succeeded fine when pulled
        # serially. The runbook additionally suggests pre-pulling.
        systemd.services =
          let
            composeDirs = lib.unique (lib.mapAttrsToList (_: r: r.composeDir) resolved);
          in
          lib.listToAttrs (map
            (dir: lib.nameValuePair "stack-${baseNameOf dir}" {
              description = "homelab compose stack: ${baseNameOf dir}";
              wantedBy = [ "multi-user.target" ];
              after = [ "docker.service" "network-online.target" ];
              requires = [ "docker.service" ];
              wants = [ "network-online.target" ];
              path = [ pkgs.docker pkgs.docker-compose ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                WorkingDirectory = dir;
                # If this stack's compose is git-tracked (composeSrc), install it
                # into the working dir first — git is the source of truth; the
                # data subtree + secret env stay alongside on /persist.
                ExecStartPre = lib.optional (srcByDir ? ${dir})
                  "${pkgs.coreutils}/bin/install -Dm0644 ${srcByDir.${dir}} ${dir}/${baseNameOf srcByDir.${dir}}";
                ExecStart = "${compose} up -d --remove-orphans";
                ExecStop = "${compose} down";
                TimeoutStartSec = "1800";
              };
            })
            composeDirs);

        # Ensure git-managed stack dirs exist (WorkingDirectory + the install
        # target above need them present, e.g. on a fresh host).
        systemd.tmpfiles.rules =
          lib.mapAttrsToList (dir: _: "d ${dir} 0755 root root -") srcByDir;

        # Native Caddy vhosts for exposed stacks + edge proxies (auto-enable
        # Caddy if any). Edge proxies point at remote upstreams (services not
        # yet migrated to this host) and reuse the same vhost treatment.
        services.caddy.enable = lib.mkDefault (exposed != { } || edgeExposed != { });
        services.caddy.virtualHosts =
          (lib.mapAttrs'
            (_name: r: lib.nameValuePair "${r.subdomain}.${domain}" {
              extraConfig = mkVhostConfig r;
            })
            exposed)
          // (lib.mapAttrs'
            (_name: r: lib.nameValuePair "${r.subdomain}.${domain}" {
              extraConfig = mkVhostConfig r;
            })
            edgeExposed);
      };
    };
}
