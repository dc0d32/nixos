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
#
# Retire when: this host is decommissioned, replaced by a successor
#   (e.g. pb-x2 / a different Lenovo gen), or its role merges with
#   another host bridge.
{ lib, config, ... }:
let
  hostName = "pb-x1";
  user = "p";
  system = "x86_64-linux";
  stateVersion = "25.11";

  # HM pkgs instance built via the shared factory in
  # ../mk-pkgs.nix (overlays + allowUnfree + allowAliases=false).
  hmPkgs = config.flake.lib.mkPkgs system;
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

  gpu.driver = "intel";

  locale = {
    timezone = "America/Los_Angeles";
    lang = "en_US.UTF-8";
  };

  # NOTE: `battery.*` is set inside `configurations.nixos.${hostName}.module`
  # below, NOT here. battery.nix declares its options as NixOS module
  # options (per-NixOS-config) so multi-laptop hosts can each carry
  # their own resumeDevice / thresholds without singleton conflicts.

  # NOTE: `audio.*` is set inside `configurations.homeManager."${user}@${hostName}".module`
  # below, NOT here. audio.nix declares its options as HM module
  # options (per-HM-config) so multi-laptop hosts can each carry
  # their own presetsDir / irsDir / autoloads without singleton
  # conflicts.

  wallpaper = {
    intervalMinutes = 30;
  };

  # NOTE: `idle.*` is set inside `configurations.homeManager."${user}@${hostName}".module`
  # below, NOT here. idle.nix declares its options as HM module
  # options (per-HM-config) so multi-laptop hosts can each carry
  # their own timeout policies and powerSaverPercent without
  # singleton conflicts.

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
        config.flake.modules.nixos.bluetooth
        config.flake.modules.nixos.boot
        config.flake.modules.nixos.login-ly
        config.flake.modules.nixos.niri
        # Auto-bootstraps p's home-manager profile on first boot of
        # any fresh install via a oneshot systemd service. No-op on
        # already-bootstrapped systems (the unit's ConditionPathExists
        # check skips it once ~/.local/state/nix/profiles/home-manager
        # exists). Same module also handles multi-user hosts.
        config.flake.modules.nixos.home-manager-bootstrap
      ];

      # Host identity + base packages + primary user.
      networking.hostName = hostName;
      users.primary = user;
      console.keyMap = "us";

      # Battery / hibernate config (declared as a NixOS module option
      # by flake-modules/battery.nix). Lenovo X1 Yoga supports kernel
      # charge thresholds via /sys/class/power_supply/BAT0/
      # charge_control_*_threshold. Capping at 80% extends battery
      # lifespan substantially. Set to 100 (and recharge to full)
      # before flying or other long unplug.
      battery = {
        chargeStopThreshold = 80;
        chargeStartThreshold = 75;
        # UPower CriticalAction at this percent. Hibernate requires a
        # swap area large enough for RAM. Falls back to PowerOff if
        # hibernate fails.
        criticalPercent = 10;
        criticalAction = "Hibernate";
        # Switch to power-profiles-daemon "power-saver" at this
        # percent on battery; restored when we go back above it.
        # Implemented by the UPower watcher inside the idled user
        # daemon.
        powerSaverPercent = 40;
        # Swap file size (GiB). Hibernate needs swap >= RAM. 32 GiB
        # matches this host's 31 GiB RAM with a margin. Created at
        # /swap/swapfile on btrfs (CoW disabled per kernel
        # requirement).
        swapSizeGiB = 32;
        # btrfs root partition holding /swap/swapfile.
        resumeDevice = "/dev/disk/by-uuid/e2ac9790-a670-4602-ba38-6aaee856b73c";
      };

      # Bootloader policy lives in flake-modules/boot.nix (imported
      # above as config.flake.modules.nixos.boot). Override individual
      # systemd-boot settings here with mkForce if this host needs to
      # diverge.
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
      imports = config.flake.lib.bundles.homeManager.desktop;

      # HM manages itself.
      programs.home-manager.enable = true;

      # Auto-lock / DPMS / suspend timings (seconds), plus the
      # power-saver-percent threshold mirrored from battery on the
      # NixOS side (40% — see battery block in the NixOS module
      # above). Declared here because idle.nix is HM-side and its
      # options are scoped per-HM-config.
      idle = {
        lockAfter = 300;
        dpmsAfter = 420;
        suspendAfter = 900;
        powerSaverPercent = 40;
      };

      # EasyEffects per-host data: preset directory, IRS directory,
      # and the per-sink autoload rules. Declared here (per-HM-config)
      # rather than at the flake-parts level so multi-laptop hosts
      # don't conflict on these values. See flake-modules/audio.nix.
      #
      # autoloads: each entry binds a single PipeWire sink (by
      # node-name) to a single EasyEffects preset; sinks without an
      # entry are left flat/passthrough. Get a sink's node-name with:
      #   wpctl inspect @DEFAULT_AUDIO_SINK@ | grep node.name
      # Add a second entry here when you author a preset for bluetooth
      # headphones (device = "bluez_output.<MAC>.1", profile is the
      # PipeWire profile name shown by `wpctl status`).
      audio = {
        presetsDir = ../../hosts/pb-x1/audio-presets;
        irsDir = ../../hosts/pb-x1/audio-irs;
        autoloads = [
          {
            device = "alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink";
            profile = "Speaker";
            description = "Alder Lake PCH-P High Definition Audio Controller Speaker";
            preset = "X1Yoga7-Dynamic-Detailed";
          }
        ];
      };

      # Per-user session vars. Editor pinned to vim because
      # flake-modules/vim.nix sets defaultEditor=true but some shells
      # / terminals don't pick that up via update-alternatives.
      # (neovim was the previous setting; it moved out of home-base
      # on 2026-05-02 — see flake-modules/vim.nix header.)
      home.sessionVariables = {
        EDITOR = "vim";
        VISUAL = "vim";
      };

      home.username = user;
      home.homeDirectory = "/home/${user}";
      home.stateVersion = stateVersion;
    };
  };
}
