# ah-1.nix — Homelab service-host VMs (ah-N family).
#
# Single dendritic host module that today produces ONE NixOS
# configuration (`ah-1`) and ONE home-manager configuration
# (`nas@ah-1`), but is structured as a factory so adding `ah-2`,
# `ah-3` etc. is just appending to the `hosts` list at the bottom.
# Each entry needs:
#   - its own hosts/<name>/hardware-configuration.nix (generated
#     inside that VM via `sudo nixos-generate-config --show-hardware-
#     config`),
#   - and that's it. Same user, same module set, same package set.
#
# Why one factory file (mirrors flake-modules/hosts/wsl.nix):
#   The bodies for ah-1, ah-2, ... are 100% identical except for the
#   hostname. Duplicating them invites drift; a factory keeps the
#   per-host knob count to exactly one (the name).
#
# Why these hosts exist:
#   General-purpose Docker service hosts on the homelab. Most workloads
#   are docker-compose stacks managed outside the flake (compose files
#   live on the VM under /var/lib/compose/<service>/), but the OS
#   itself (kernel, sshd, dockerd, base packages, user account) is
#   declarative.
#
# Why a dedicated `nas` user (not `p`):
#   These are unattended service hosts shared across the homelab; the
#   account that operates them is a role account, not a personal one.
#   Keeping it separate from `p` means SSH keys, shell history, and
#   group memberships for the role account don't leak into desktop
#   workflows and vice versa.
#
# Why headless module set:
#   No GUI (niri/quickshell/wallpaper/idle/desktop-extras), no
#   GUI-only HM (alacritty, chrome, vscode, freecad), no audio,
#   no battery, no biometrics, no hardware-hacking groups. The HM
#   bundle mirrors the wsl.nix headless set (zsh, tmux, neovim, btop,
#   git, direnv, gh, ai-cli, build-deps) so SSHing into any homelab
#   VM feels like SSHing into WSL: same shell, same prompt, same
#   muscle memory.
#
# Why no Tailscale / no reverse proxy / no oci-containers:
#   Per the design questions, the user explicitly chose SSH-only
#   remote access (the homelab is LAN-reachable), no reverse proxy
#   yet (services on raw host:port until enough of them exist to
#   warrant Caddy/Traefik), and external docker-compose for stack
#   management (no NixOS-managed containers). All three are easy
#   additions later: drop in flake-modules/tailscale.nix, /caddy.nix,
#   etc., and import here.
#
# Rebuild from inside an ah-N VM:
#   sudo nixos-rebuild switch --flake .#ah-1
#   home-manager switch --flake .#'nas@ah-1'
#
# Adding ah-2:
#   1. Provision the VM in the homelab hypervisor.
#   2. mkdir hosts/ah-2 ; sudo nixos-generate-config \
#        --show-hardware-config > hosts/ah-2/hardware-configuration.nix
#   3. Append `{ name = "ah-2"; system = "x86_64-linux"; }` to the
#      `hosts` list at the bottom of this file.
#   4. git add and rebuild.
#
# Retire when:
#   - The homelab moves off Docker (e.g. to k3s/Nomad), at which
#     point the docker.nix import here goes away and is replaced by
#     a kubelet/nomad-client module; OR
#   - The ah-N family converges with another host class to the point
#     where one host module can serve both (unlikely -- desktop and
#     server are intentionally divergent).
{ inputs, config, ... }:
let
  user = "nas";
  stateVersion = "25.11";

  # Per-arch pkgs instance with repo-wide overlays applied. Memoised
  # via let-binding so each system is imported once.
  mkPkgs = system: import inputs.nixpkgs {
    inherit system;
    overlays = import ../../overlays;
    config = {
      allowUnfree = true;
      allowAliases = false;
    };
  };

  # NixOS module shared by every ah-N. Headless server-class --
  # NOT importing: gpu, power, battery, audio, biometrics, login-ly,
  # niri, fonts, hardware-hacking, chromium-managed, steam, timekpr.
  mkNixosModule = { name, system }: { lib, pkgs, ... }: {
    imports = [
      ../../hosts/${name}/hardware-configuration.nix

      config.flake.modules.nixos.nix-settings
      config.flake.modules.nixos.system-utils
      config.flake.modules.nixos.users
      config.flake.modules.nixos.locale
      config.flake.modules.nixos.networking
      config.flake.modules.nixos.openssh
      config.flake.modules.nixos.docker
    ];

    nixpkgs.hostPlatform = lib.mkDefault system;
    networking.hostName = name;
    users.primary = user;
    console.keyMap = "us";

    # UEFI by default (modern hypervisors ship OVMF). If the VM is
    # provisioned with legacy BIOS, override boot.loader.grub here in
    # the regenerated hardware-configuration.nix or in a per-host
    # tweak below.
    boot.loader.systemd-boot.enable = lib.mkDefault true;
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

    # Service-account user. Throwaway initial password; rotate on
    # first login or replace with sops-managed hashedPasswordFile
    # once secrets are bootstrapped (see secrets/README.md).
    users.users.${user} = {
      isNormalUser = true;
      description = user;
      # `wheel` for sudo, `networkmanager` to manage NICs without
      # sudo, `docker` is added by flake-modules/docker.nix off
      # `users.primary`.
      extraGroups = [ "wheel" "networkmanager" ];
      shell = pkgs.zsh;
      initialPassword = "changeme";
    };

    # Minimal system package set; rest lives in home-manager.
    environment.systemPackages = with pkgs; [
      git
      vim
      curl
      wget
    ];

    system.stateVersion = stateVersion;
  };

  # Headless HM bundle shared by every nas@ah-N. Mirrors the wsl.nix
  # set (same SSH muscle memory) minus build-deps (these are service
  # hosts, not dev workstations -- pull build-deps in per-host if a
  # specific VM needs gcc/make for compiling some daemon).
  hmModule = {
    imports = [
      config.flake.modules.homeManager.git
      config.flake.modules.homeManager.tmux
      config.flake.modules.homeManager.direnv
      config.flake.modules.homeManager.btop
      config.flake.modules.homeManager.gh
      config.flake.modules.homeManager.zsh
      config.flake.modules.homeManager.neovim
    ];

    programs.home-manager.enable = true;

    home.sessionVariables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
    };

    home.username = user;
    home.homeDirectory = "/home/${user}";
    home.stateVersion = stateVersion;
  };

  # Add new VMs by appending to this list. Each (name, system) pair
  # produces one NixOS config and one HM config (`<user>@<name>`).
  hosts = [
    { name = "ah-1"; system = "x86_64-linux"; }
  ];
in
{
  # Cross-host shared option values. All ah-N VMs share these.
  git = {
    name = "CHANGEME";
    email = "CHANGEME@example.com";
  };

  locale = {
    timezone = "America/Los_Angeles";
    lang = "en_US.UTF-8";
  };

  # NixOS configurations -- one per (name, system) pair.
  # All ah-N hosts are placeholders until their VMs are provisioned and
  # `nixos-generate-config` overwrites their hardware-configuration.nix.
  # The auto-check skips placeholders so pure `nix flake check` keeps
  # passing on the dev box. To smoke-build anyway:
  #   NIXOS_ALLOW_PLACEHOLDER=1 nix build --impure \
  #     .#nixosConfigurations.ah-1.config.system.build.toplevel
  configurations.nixos = builtins.listToAttrs (map
    ({ name, system }: {
      inherit name;
      value = {
        placeholder = true;
        module = mkNixosModule { inherit name system; };
      };
    })
    hosts);

  # Home-manager configurations -- one per host, named "${user}@${name}".
  configurations.homeManager = builtins.listToAttrs (map
    ({ name, system }: {
      name = "${user}@${name}";
      value = {
        pkgs = mkPkgs system;
        module = hmModule;
      };
    })
    hosts);
}
