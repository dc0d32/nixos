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
          inherit (r) composeDir subdomain upstream;
          expose = if s.expose != null then s.expose else r.exposeDefault;
          auth = if s.auth != null then s.auth else r.authDefault;
        };
      resolved = lib.mapAttrs resolve valid;
      exposed = lib.filterAttrs (_: r: r.expose != "none") resolved;
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

      config = lib.mkIf (enabled != { }) {
        assertions =
          (lib.mapAttrsToList
            (name: _: {
              assertion = registry ? ${name};
              message = "homelab.stacks.${name}: no matching homelab.registry.${name} entry.";
            })
            enabled)
          ++ [{
            assertion = (exposed == { }) -> (domain != "");
            message = "homelab.domain must be set when any stack is exposed.";
          }];

        # One oneshot per placed stack: docker compose up -d in its dir.
        systemd.services = lib.mapAttrs'
          (name: r: lib.nameValuePair "stack-${name}" {
            description = "homelab compose stack: ${name}";
            wantedBy = [ "multi-user.target" ];
            after = [ "docker.service" "network-online.target" ];
            requires = [ "docker.service" ];
            wants = [ "network-online.target" ];
            path = [ pkgs.docker pkgs.docker-compose ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              WorkingDirectory = r.composeDir;
              ExecStart = "${compose} up -d --remove-orphans";
              ExecStop = "${compose} down";
              TimeoutStartSec = "600";
            };
          })
          resolved;

        # Native Caddy vhosts for exposed stacks (auto-enable Caddy if any).
        services.caddy.enable = lib.mkDefault (exposed != { });
        services.caddy.virtualHosts = lib.mapAttrs'
          (_name: r: lib.nameValuePair "${r.subdomain}.${domain}" {
            extraConfig = ''
              reverse_proxy ${r.upstream}
            '';
          })
          exposed;
      };
    };
}
