# nixtest.nix — throwaway NixOS VM to validate the homelab install loop.
#
# Why this exists (Phase 0 of the homelab migration):
#   Proves the whole guest loop on real Proxmox BEFORE touching any
#   production host: `nixos-anywhere` install → disko `vm` layout on
#   /dev/vda → docker → a declarative NFS mount (flake.modules.nixos
#   .nfs-client) → native hardened Caddy (flake.modules.nixos.caddy)
#   reverse-proxying a test container. Zero production risk — provision a
#   scratch VM (reuse the arch-test slot or a new one), install, verify,
#   destroy.
#
# Why NOT `disko-safety` here:
#   This is a single-disk VM; /dev/vda is stable inside a VM, and
#   disko-safety intentionally rejects non-by-id paths — that guard is for
#   the multi-disk bare-metal nodes, not VMs.
#
# Rebuild from inside the VM:
#   sudo nixos-rebuild switch --flake .#nixtest
#   home-manager switch --flake .#'p@nixtest'
#
# Retire when:
#   * Phase 0 is proven and the real bare-metal hosts exist — delete
#     this file and hosts/nixtest/.
{ config, ... }:
let
  # Operator/login user is `p` (the human). `nas` is reserved as an NFS
  # service account only, not a login — so homelab hosts log in as `p`.
  user = "p";
  name = "nixtest";
  system = "x86_64-linux";
  stateVersion = "25.11";

  mkPkgs = config.flake.lib.mkPkgs;

  nixosModule = { lib, pkgs, ... }: {
    imports = [
      ../../hosts/nixtest/hardware-configuration.nix

      # Declarative disk layout — VM template (UEFI ESP + ext4 root).
      config.flake.modules.nixos.disko
      (config.flake.lib.diskoLayouts.vm {
        disk = "/dev/vda";
      })

      # Base server-class modules (same set as ah-1).
      config.flake.modules.nixos.nix-settings
      config.flake.modules.nixos.system-utils
      # /bin/bash FHS shim — the Copilot CLI hardcodes that path and is
      # otherwise unusable as an agent here. See
      # flake-modules/bin-bash.nix.
      config.flake.modules.nixos.bin-bash
      config.flake.modules.nixos.users
      config.flake.modules.nixos.locale
      config.flake.modules.nixos.networking
      config.flake.modules.nixos.openssh
      config.flake.modules.nixos.boot
      config.flake.modules.nixos.docker

      # New homelab modules under test.
      config.flake.modules.nixos.nfs-client
      config.flake.modules.nixos.caddy
      # Imported inert (no host config set) purely to eval-validate them on
      # this throwaway host; each is a no-op until its options are set.
      config.flake.modules.nixos.secrets
      config.flake.modules.nixos.zfs-storage
      config.flake.modules.nixos.sanoid
      config.flake.modules.nixos.nfs-server
      config.flake.modules.nixos.samba
      config.flake.modules.nixos.syncoid
      config.flake.modules.nixos.offsite-restic
      config.flake.modules.nixos.offsite-rclone
      config.flake.modules.nixos.nvidia-server
      config.flake.modules.nixos.crowdsec
      config.flake.modules.nixos.ddns
      config.flake.modules.nixos.virt-host
      config.flake.modules.nixos.stacks-registry
      config.flake.modules.nixos.stacks

      # Bootstrap the p user's HM profile on first boot.
      config.flake.modules.nixos.home-manager-bootstrap
    ];

    nixpkgs.hostPlatform = lib.mkDefault system;
    networking.hostName = name;
    users.primary = user;

    users.users.${user} = config.flake.lib.mkUser {
      name = user;
      admin = true;
      shell = pkgs.zsh;
    };

    # ---- proof payload -------------------------------------------------
    # A declarative NFS mount. Automounted + _netdev, so an absent server
    # doesn't block boot while testing. Points at an existing export.
    homelab.nfs.mounts."/mnt/test" = {
      device = "192.0.2.3:/mnt/tank/nas";
    };

    # Native, hardened Caddy reverse-proxying to a test container on :8080
    # (run e.g. `docker run -p 8080:80 traefik/whoami` after install).
    services.caddy = {
      enable = true;
      virtualHosts."http://nixtest.lan".extraConfig = ''
        reverse_proxy 127.0.0.1:8080
      '';
    };
    # --------------------------------------------------------------------

    system.stateVersion = stateVersion;
  };

  hmModule = {
    imports = config.flake.lib.bundles.homeManager.homelab;
    programs.home-manager.enable = true;
    home.username = user;
    home.homeDirectory = "/home/${user}";
    home.stateVersion = stateVersion;
  };
in
{
  # Placeholder until the VM exists and nixos-generate-config overwrites
  # hosts/nixtest/hardware-configuration.nix. Filtered from flake.checks;
  # smoke-build with NIXOS_ALLOW_PLACEHOLDER=1 (see hardware stub).
  configurations.nixos.${name} = {
    placeholder = true;
    module = nixosModule;
  };

  configurations.homeManager."${user}@${name}" = {
    pkgs = mkPkgs system;
    module = hmModule;
  };
}
