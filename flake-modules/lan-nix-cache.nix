# LAN Nix binary-cache client.
#
# Why this exists: the home fleet shares most of its Linux closures, so each
# host should try the signed Attic cache on the trusted LAN before downloading
# the same paths from the internet. The endpoint and public key are mandatory
# host policy: importing this module without both is an evaluation error rather
# than silently weakening signature verification.
#
# The module is intentionally not in a bundle yet. Attic generates the cache
# signing keypair when the cache is first created on Andromeda; clients are
# imported only after that one-time bootstrap exposes the public half.
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
          example = "http://cache.example.test:8080/nix";
          description = "Signed Attic binary-cache endpoint.";
        };
        publicKey = lib.mkOption {
          type = lib.types.str;
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
            assertion = lib.hasInfix ":" cfg.publicKey;
            message = "lanNixCache.publicKey must be a canonical Nix public key.";
          }
        ];

        nix.settings = {
          substituters = lib.mkBefore [ cfg.endpoint ];
          trusted-public-keys = [ cfg.publicKey ];
          connect-timeout = lib.mkDefault cfg.connectTimeoutSeconds;
          fallback = lib.mkDefault true;
        };
      };
    };
}
