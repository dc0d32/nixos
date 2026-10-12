# LAN Nix binary-cache client.
#
# Why this exists: the home fleet shares its Linux and native Mac closures, so each
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
let
  cacheOptions = { config, lib, ... }:
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
      };
    };
  cacheSettings = cfg: lib: {
    connect-timeout = lib.mkDefault cfg.connectTimeoutSeconds;
    fallback = lib.mkDefault true;
    require-sigs = lib.mkDefault true;
  };
in
{
  flake.modules.nixos.lan-nix-cache = { config, lib, ... }: {
    imports = [ cacheOptions ];
    nix.settings = cacheSettings config.lanNixCache lib // {
      substituters = lib.mkBefore [
        config.lanNixCache.endpoint
        config.lanNixCache.upstreamProxyEndpoint
      ];
      trusted-public-keys = [ config.lanNixCache.publicKey ];
    };
  };

  # Only user config and commands: daemon trust is an explicit administrator
  # action, not HM activation. Extra settings preserve installer/public caches.
  flake.modules.homeManager.lan-nix-cache = { config, lib, pkgs, ... }:
    let
      cfg = config.lanNixCache;
      upload = pkgs.writeShellApplication {
        name = "nix-cache-upload";
        runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.nix pkgs.openssh pkgs.openssl ];
        text = ''
          if [[ "$#" -eq 1 && "$1" == "--profile" ]]; then
            set -- ${lib.escapeShellArg "${config.xdg.stateHome}/nix/profiles/home-manager"}
          elif [[ "$#" -eq 0 || "$1" == "--help" ]]; then
            echo "Usage: nix-cache-upload --profile | <store-root-or-result>..."
            echo "Publishes the selected closures to the public LAN cache via SSH and interactive sudo."
            [[ "$#" -gt 0 ]] && exit 0
            exit 2
          fi

          roots=()
          for input in "$@"; do
            root="$(realpath -e -- "$input")"
            if [[ ! "$root" =~ ^/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$ ]]; then
              echo "Expected a canonical store root (no subpaths): $input" >&2
              exit 2
            fi
            roots+=("$root")
          done
          nix-store --check-validity "''${roots[@]}"
          curl --noproxy '*' --fail --silent --show-error \
            --connect-timeout ${toString cfg.connectTimeoutSeconds} --max-time 8 \
            ${lib.escapeShellArg "${cfg.endpoint}/nix-cache-info"} >/dev/null

          remote=${lib.escapeShellArg cfg.uploadSshTarget}
          ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5)
          if ! ssh "''${ssh_options[@]}" "$remote" \
            'test -x /run/current-system/sw/bin/nix-cache-stage && test -x /run/current-system/sw/bin/nix-cache-publish'; then
            echo "Deploy the cache host's SSH upload helpers and verify its pinned SSH identity first." >&2
            exit 1
          fi
          closure_text="$(nix-store --query --requisites "''${roots[@]}")"
          mapfile -t closure <<< "$closure_text"
          id="$(openssl rand -hex 16)"
          cleanup() {
            local status=$?
            # shellcheck disable=SC2029
            if ! ssh "''${ssh_options[@]}" "$remote" \
              "rm -f -- .local/state/nix-cache-upload/$id.nar"; then
              echo "Could not clean remote stage $id; remove it on the cache host." >&2
              if [[ "$status" -eq 0 ]]; then
                exit 1
              fi
            fi
          }
          trap cleanup EXIT
          echo "Exporting selected closures; all their contents will be publicly readable from Attic." >&2
          # shellcheck disable=SC2029
          nix-store --export "''${closure[@]}" \
            | ssh "''${ssh_options[@]}" "$remote" nix-cache-stage "$id"
          # Root names and the ID have restricted alphabets: SSH's remote shell
          # cannot interpret them as commands. No credentials leave the server.
          ssh -t "''${ssh_options[@]}" "$remote" \
            sudo /run/current-system/sw/bin/nix-cache-publish "$id" "''${roots[@]}"
        '';
      };
      build = pkgs.writeShellApplication {
        name = "nix-cache-build";
        runtimeInputs = [ pkgs.nix upload ];
        text = ''
          if [[ "$#" -eq 0 || "$1" == "--help" ]]; then
            echo "Usage: nix-cache-build <nix build arguments...>"
            echo "Builds natively, then explicitly publishes just the output closures."
            [[ "$#" -gt 0 ]] && exit 0
            exit 2
          fi
          outputs="$(nix build --print-out-paths "$@")"
          if [[ -z "$outputs" ]]; then
            echo "No build outputs to upload." >&2
            exit 1
          fi
          mapfile -t roots <<< "$outputs"
          nix-cache-upload "''${roots[@]}"
        '';
      };
    in
    {
      imports = [ cacheOptions ];
      options.lanNixCache.uploadSshTarget = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*";
        default = "p@nix-cache.lan";
        description = "Existing SSH operator account on the cache host, with interactive sudo.";
      };
      config = {
        nix.package = lib.mkDefault pkgs.nix;
        nix.settings = cacheSettings cfg lib // {
          extra-substituters = lib.mkBefore [ cfg.endpoint cfg.upstreamProxyEndpoint ];
          extra-trusted-public-keys = [ cfg.publicKey ];
          experimental-features = lib.mkDefault [ "nix-command" "flakes" ];
        };
        xdg.configFile."nix/lan-cache-daemon.conf".text = ''
          # Administrator-installed daemon trust; HM never modifies /etc.
          extra-trusted-substituters = ${cfg.endpoint} ${cfg.upstreamProxyEndpoint}
          extra-trusted-public-keys = ${cfg.publicKey}
          require-sigs = true
        '';
        home.packages = [ upload build ];
      };
    };
}
