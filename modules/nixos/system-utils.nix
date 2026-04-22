{ pkgs, ... }:
# System-level utilities every NixOS host should have: partitioning,
# filesystem, build essentials, recovery tools. User-level dev toolchain
# lives in modules/home/tools/build-deps.nix instead.
{
  environment.systemPackages = with pkgs; [
    # Partitioning / filesystems
    util-linux       # fdisk, cfdisk, lsblk, blkid, mount, etc.
    parted
    gptfdisk         # sgdisk / cgdisk
    dosfstools
    e2fsprogs
    ntfs3g
    exfatprogs
    cryptsetup

    # Disk I/O
    hdparm
    smartmontools
    nvme-cli

    # Build essentials needed system-wide (e.g. for out-of-tree kernel modules,
    # nixpkgs builds, user shell sessions that call make outside a nix-shell)
    gcc
    gnumake
    binutils
    pkg-config

    # Text / inspection
    file
    tree
    ripgrep
    fd

    # Recovery / network
    curl
    wget
    rsync
    openssh
    tmux
    htop

    # nmtui lives inside networkmanager, which is already enabled in
    # modules/nixos/networking.nix — nothing to add here for that.
  ];
}
