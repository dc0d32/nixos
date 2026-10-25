# Build deps & general-purpose CLI tooling installed for the user on
# every system that imports this module. Keep this list lean; host-
# specific extras belong in hosts/<h>/host-packages.nix or the user's
# home.nix.
#
# Retire when: per-project nix shells / devShells fully replace the
#   need for a user-level baseline toolchain, OR the contents move
#   into more focused per-language modules.
{
  flake.modules.homeManager.build-deps = { pkgs, ... }: {
    home.packages = with pkgs; [
      # Build toolchain
      gcc
      gnumake
      cmake
      pkg-config
      autoconf
      automake
      libtool

      # Languages
      python3
      # nodejs 24.21.0 predates the 2026-10 security release; use the patched
      # maintained line until the default nodejs package reaches 24.22.1.
      nodejs_22

      # tree-sitter CLI — available from the shell for grammar
      # development (parser generation, `tree-sitter test`, etc.).
      tree-sitter

      # Archive / transfer
      unzip
      zip
      gnutar
      xz
      zstd
      rsync
      curl
      wget

      # Inspection
      file
      tree
      jq
      yq-go
      which

      # Network
      dig
      nmap
      iperf3
    ];
  };
}
