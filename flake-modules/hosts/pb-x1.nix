# pb-x1 — primary dev laptop (Lenovo X1 Yoga gen 7, x86_64-linux).
#
# Naming: `pb-x1` = "pb" (initials) + "x1" (X1 Yoga). Renamed from
# the earlier generic `laptop` once a second laptop became part of
# the plan.
#
# Dendritic host module. Sets top-level option values for every
# feature module this host imports, and lists the full set of
# {nixos, homeManager} contributions to wire up.
#
# To add a feature: write flake-modules/<feature>.nix that contributes
# to flake.modules.<class>.<feature>, then add a line to the
# `imports = [ … ]` list below for whichever class it belongs to.
{ inputs, lib, config, ... }:
let
  hostName = "pb-x1";
  user = "p";
  system = "x86_64-linux";
  stateVersion = "25.11";

  # HM pkgs instance with repo-wide overlays.
  #   - allowUnfree for chrome/vscode/etc.
  #   - allowAliases = false to silence transitive deprecation warnings
  #     (e.g. nvim-treesitter-legacy) on pinned nixos-unstable
  hmPkgs = import inputs.nixpkgs {
    inherit system;
    overlays = import ../../overlays;
    config = {
      allowUnfree = true;
      allowAliases = false;
    };
  };
in
{
  # ── Top-level option values supplied by this host ────────────────
  # Each setting here is read by a feature module under
  # ./flake-modules/<feature>.nix. See that module for the option
  # type and how it's consumed.
  #
  # NOTE: per-host values that are conceptually per-NixOS-config
  # (hostname, primary user, system tuple, state version) are NOT set
  # at the flake-parts level — they live inside the
  # `configurations.nixos.${hostName}.module` block below. Setting
  # them up here would create a flake-parts singleton that conflicts
  # the moment a second host with different values shows up.

  git = {
    name = "CHANGEME";
    email = "CHANGEME@example.com";
  };

  # ── Secrets (sops-nix) — opt-in ─────────────────────────────────
  # Uncomment after running the bootstrap in secrets/README.md, then:
  #   1. Drop the literal git.name / git.email above and use
  #      `git.identityFile = config.sops.secrets.git_identity.path;`
  #      inside the `module = { ... }` block of the homeManager config below
  #      (where `config` resolves to the HM-side config).
  #   2. Set the values here:
  # secrets = {
  #   ageKeyFile = "/home/${user}/.config/sops/age/keys.txt";
  #   commonFile = ../../secrets/common.yaml;
  # };

  gpu.driver = "intel";

  locale = {
    timezone = "America/Los_Angeles";
    lang = "en_US.UTF-8";
  };

  battery = {
    # Lenovo X1 Yoga supports kernel charge thresholds via
    # /sys/class/power_supply/BAT0/charge_control_*_threshold.
    # Capping at 80% extends battery lifespan substantially. Set to 100
    # (and recharge to full) before flying or other long unplug.
    chargeStopThreshold = 80;
    chargeStartThreshold = 75;
    # UPower CriticalAction at this percent. Hibernate requires a swap
    # area large enough for RAM. Falls back to PowerOff if hibernate
    # fails.
    criticalPercent = 10;
    criticalAction = "Hibernate";
    # Switch to power-profiles-daemon "power-saver" at this percent on
    # battery; restored to whatever profile was active when we descended
    # past the threshold the next time we go above it. Implemented by
    # the UPower watcher inside the idled user daemon.
    powerSaverPercent = 40;
    # Swap file size (GiB). Hibernate needs swap >= RAM. 32 GiB matches
    # this host's 31 GiB RAM with a margin. Created at /swap/swapfile on
    # btrfs (CoW disabled per kernel requirement).
    swapSizeGiB = 32;
    # btrfs root partition holding /swap/swapfile.
    resumeDevice = "/dev/disk/by-uuid/e2ac9790-a670-4602-ba38-6aaee856b73c";
  };

  audio = {
    preset = "X1Yoga7-Dynamic-Detailed";
    presetsDir = ../../hosts/pb-x1/audio-presets;
    irsDir = ../../hosts/pb-x1/audio-irs;
    # Autoload: apply preset automatically when this output device appears.
    # Get the device name with: wpctl inspect @DEFAULT_AUDIO_SINK@ | grep node.name
    autoloadDevice = "alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink";
    autoloadDeviceProfile = "Speaker";
    autoloadDeviceDescription = "Alder Lake PCH-P High Definition Audio Controller Speaker";
  };

  wallpaper = {
    intervalMinutes = 30;
  };

  # Auto-lock / DPMS / suspend timings (seconds).
  idle = {
    lockAfter = 300;
    dpmsAfter = 420;
    suspendAfter = 900;
  };

  # ── Per-host configuration entries ───────────────────────────────
  configurations.nixos.${hostName} = {
    module = {
      imports = [
        ../../hosts/pb-x1/hardware-configuration.nix
        # Migrated dendritic feature modules (NixOS side).
        config.flake.modules.nixos.hardware-hacking
        config.flake.modules.nixos.gpu
        config.flake.modules.nixos.power
        config.flake.modules.nixos.networking
        config.flake.modules.nixos.nix-settings
        config.flake.modules.nixos.system-utils
        config.flake.modules.nixos.users
        config.flake.modules.nixos.fonts
        config.flake.modules.nixos.locale
        config.flake.modules.nixos.battery
        config.flake.modules.nixos.audio
        config.flake.modules.nixos.biometrics
        config.flake.modules.nixos.login-ly
        config.flake.modules.nixos.niri
      ];

      # Host identity + base packages + primary user. These were the
      # last bits of the legacy hosts/laptop/configuration.nix; folded
      # in here to eliminate the duplicate level of indirection.
      networking.hostName = hostName;
      users.primary = user;
      console.keyMap = "us";

      # Bootloader: standard UEFI boot.
      boot.loader.systemd-boot.enable = lib.mkDefault true;
      boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
      boot.kernelPackages = hmPkgs.linuxPackages_latest;

      # Primary user.
      users.users.${user} = {
        isNormalUser = true;
        description = user;
        # `input` group: required by idled to read /dev/input/event*
        # directly. See flake-modules/idle.nix and packages/idled/.
        extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" ];
        shell = hmPkgs.zsh;
      };

      # Extra system packages specific to this host. Most packages live
      # in home-manager; reserve this for things that must exist at the
      # system level (early boot tools, recovery shell tools).
      environment.systemPackages = with hmPkgs; [
        git
        vim
        curl
        wget
      ];

      system.stateVersion = stateVersion;
    };
  };

  configurations.homeManager."${user}@${hostName}" = {
    pkgs = hmPkgs;
    module = {
      imports = [
        # Migrated dendritic feature modules (HM side).
        config.flake.modules.homeManager.git
        config.flake.modules.homeManager.tmux
        config.flake.modules.homeManager.direnv
        config.flake.modules.homeManager.fonts
        config.flake.modules.homeManager.btop
        config.flake.modules.homeManager.build-deps
        config.flake.modules.homeManager.gh
        config.flake.modules.homeManager.ai-cli
        config.flake.modules.homeManager.hardware-hacking
        config.flake.modules.homeManager.audio
        config.flake.modules.homeManager.polkit-agent
        config.flake.modules.homeManager.chrome
        config.flake.modules.homeManager.bitwarden
        config.flake.modules.homeManager.vscode
        config.flake.modules.homeManager.alacritty
        config.flake.modules.homeManager.zsh
        config.flake.modules.homeManager.desktop-extras
        config.flake.modules.homeManager.wallpaper
        config.flake.modules.homeManager.idle
        config.flake.modules.homeManager.freecad
        config.flake.modules.homeManager.neovim
        config.flake.modules.homeManager.niri
        config.flake.modules.homeManager.quickshell
        # ── Secrets (sops-nix) ──
        # Uncomment after bootstrap (see secrets/README.md):
        # config.flake.modules.homeManager.secrets
      ];

      # HM manages itself (last bit from the legacy modules/home/default.nix).
      programs.home-manager.enable = true;

      # Per-user session vars (last bit from the legacy
      # homes/<user>@<host>/home.nix). Editor pinned to nvim because
      # flake-modules/neovim.nix sets defaultEditor=true but some shells
      # / terminals don't pick that up via update-alternatives.
      home.sessionVariables = {
        EDITOR = "nvim";
        VISUAL = "nvim";
      };

      home.username = user;
      home.homeDirectory = "/home/${user}";
      home.stateVersion = stateVersion;
    };
  };
}
