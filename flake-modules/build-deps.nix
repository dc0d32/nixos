# Build deps & general-purpose CLI tooling installed for the user on
# every system that imports this module. Keep this list lean; host-
# specific extras belong in hosts/<h>/host-packages.nix or the user's
# home.nix.
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
      nodejs

      # tree-sitter CLI — lives in home.packages (not neovim's
      # extraPackages) so :checkhealth nvim-treesitter finds it on
      # PATH, and so it's available from the shell for grammar
      # development / :TSInstall / :TSUpdate.
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
