# stacks-registry.nix — the single, DRY definition of every homelab docker
# stack (data only; no config).
#
# Why this exists:
#   Each stack is described ONCE here (compose dir, subdomain, upstream,
#   default exposure/auth, placement hints). Host bridges then just list
#   which stacks run on them via `homelab.stacks` (see stacks.nix), so
#   "move a service between nodes" = move its line between two host files.
#   Keeping the registry separate from placement keeps the definitions
#   stable while placement churns.
#
# Compose files may live either on-disk only (`composeDir`) or be git-tracked
# and installed into `composeDir` at unit start (`composeSrc`, see stacks.nix).
# Secrets and data always stay on `composeDir`/`/persist`, never in the store.
#
# Retire when: the homelab adopts an orchestrator (Nomad) that owns the
#   service catalog, at which point this registry feeds the Nomad jobs
#   instead of the static compose-up units.
{ ... }:
{
  flake.modules.nixos.stacks-registry = { lib, ... }: {
    options.homelab.domain = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "example.com";
      description = "Base domain; stacks are served at <subdomain>.<domain>.";
    };

    options.homelab.registry = lib.mkOption {
      default = { };
      description = "Canonical definition of every homelab stack.";
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          composeDir = lib.mkOption {
            type = lib.types.str;
            example = "/persist/stacks/immich";
            description = "On-disk dir holding this stack's compose file.";
          };
          composeSrc = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            example = lib.literalExpression "../stacks/immich/docker-compose.yml";
            description = ''
              Optional git-tracked compose file for this stack. When set, the
              stack unit installs it into `composeDir` (as its basename) before
              `docker compose up`, so the compose BODY is versioned in-repo
              while data + secrets stay on `composeDir`/`/persist`. Leave null
              for stacks whose compose still lives only on disk.
            '';
          };
          subdomain = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Subdomain under homelab.domain.";
          };
          upstream = lib.mkOption {
            type = lib.types.str;
            example = "127.0.0.1:2283";
            description = "host:port Caddy reverse-proxies to.";
          };
          exposeDefault = lib.mkOption {
            type = lib.types.enum [ "none" "lan" "public" ];
            default = "lan";
          };
          authDefault = lib.mkOption {
            type = lib.types.enum [ "none" "authentik" "basic" ];
            default = "none";
          };
          gpu = lib.mkOption { type = lib.types.bool; default = false; };
          tlsUpstream = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Upstream speaks HTTPS (e.g. code-server) — Caddy proxies with
              `https://` + tls_insecure_skip_verify instead of plain http.
            '';
          };
          data = lib.mkOption {
            type = lib.types.enum [ "none" "local" "zrust" ];
            default = "none";
            description = "Where the stack's state lives (placement hint).";
          };
        };
      }));
    };
  };
}
