{ pkgs, lib, ... }:
# Build deps & general-purpose CLI tooling installed for the user on every
# system (NixOS + macOS). Keep this list lean; host-specific extras belong in
# hosts/<h>/host-packages.nix or the user's home.nix.
{
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
}
