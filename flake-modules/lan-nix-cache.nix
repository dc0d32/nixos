# LAN Nix binary-cache client.
#
# Why this exists: the home fleet shares most of its Linux closures, so each
# host should try the signed Attic cache on the trusted LAN before downloading
# the same paths from the internet. A pull-through proxy for cache.nixos.org is
# second: its first request fills Andromeda's disk cache and later clients reuse
# it without duplicating those upstream-signed paths into Attic. The normal
# public caches remain later substituters, so roaming hosts fail through safely.
#
# Both LAN endpoints use one stable DNS service alias rather than a physical
# host name, so moving the cache later does not require touching every client.
#
# The public key is safe to publish: only the private half can sign paths, and
# that private key remains in the cache host's out-of-store secret storage.
#
# Retire when: the fleet stops using a LAN cache, or Nix gains an equivalent
# authenticated peer/cache-discovery mechanism.
{ ... }:
{
  flake.modules.nixos.lan-nix-cache = { config, lib, ... }:
    let
      cfg = config.lanNixCache;
    in
    {
      options.lanNixCache = {
        endpoint = lib.mkOption {
          type = lib.types.str;
          default = "http://nix-cache.lan:8080/nix";
          example = "http://cache.example.test:8080/nix";
          description = "Signed Attic binary-cache endpoint.";
        };
        upstreamProxyEndpoint = lib.mkOption {
          type = lib.types.str;
          default = "http://nix-cache.lan:8081";
          example = "http://cache.example.test:8081";
          description = "Pull-through proxy for cache.nixos.org.";
        };
        publicKey = lib.mkOption {
          type = lib.types.str;
          default = "home-nix-cache-1:5s+6+8LuJKjQ505gMSrxVi8XBpDNWhXTrM0ipdSZLNQ=";
          example = "nix:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          description = "Nix public signing key advertised by the Attic cache.";
        };
        connectTimeoutSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 3;
          description = ''
            Connection timeout for substituters. This keeps an off-LAN cache
            miss from delaying every Nix command on a roaming machine.
          '';
        };
      };

      config = {
        assertions = [
          {
            assertion = lib.hasPrefix "http://" cfg.endpoint || lib.hasPrefix "https://" cfg.endpoint;
            message = "lanNixCache.endpoint must be an HTTP(S) URL.";
          }
          {
            assertion =
              lib.hasPrefix "http://" cfg.upstreamProxyEndpoint
              || lib.hasPrefix "https://" cfg.upstreamProxyEndpoint;
            message = "lanNixCache.upstreamProxyEndpoint must be an HTTP(S) URL.";
          }
          {
            assertion = lib.hasInfix ":" cfg.publicKey;
            message = "lanNixCache.publicKey must be a canonical Nix public key.";
          }
        ];

        nix.settings = {
          substituters = lib.mkBefore [
            cfg.endpoint
            cfg.upstreamProxyEndpoint
          ];
          trusted-public-keys = [ cfg.publicKey ];
          connect-timeout = lib.mkDefault cfg.connectTimeoutSeconds;
          fallback = lib.mkDefault true;
        };
      };
    };
}
