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
{ lib, config, inputs, ... }:
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

  # git identity, locale/timezone and wallpaper interval all use their
  # module defaults now (git.nix → CHANGEME, locale.nix →
  # America/Los_Angeles + en_US.UTF-8, wallpaper.nix → 30min), so there
  # are no top-level option values to set on this host.
  #
  # NOTE: `gpu.driver` and `battery.*` are set inside
  # `configurations.nixos.${hostName}.module`, and `audio.*` / `idle.*`
  # inside `configurations.homeManager."${user}@${hostName}".module` —
  # NOT here. Those options are declared per-(NixOS|HM)-config so
  # multi-host setups don't collide on a flake-parts singleton.

  # ── Per-host configuration entries ───────────────────────────────
  configurations.nixos.${hostName} = {
    module = {
      imports = [
        ../../hosts/pb-x1/hardware-configuration.nix
        # Disko: declarative disk layout. Provides config.fileSystems.*
        # (root/nix/home/.snapshots subvols, /boot ESP) plus a 32G
        # swap partition from the shared bare-metal layout factory;
        # flake.modules.nixos.disko imports inputs.disko.nixosModules.disko
        # which actually synthesizes the fileSystems + swapDevices +
        # resumeDevice entries from disko.devices.
        # /dev/nvme0n1 — single onboard NVMe on this Lenovo X1 Yoga.
        config.flake.modules.nixos.disko
        (config.flake.lib.diskoLayouts.bare-metal {
          disk = "/dev/nvme0n1";
          # 32 GiB swap partition — RAM is 31 GiB so this clears the
          # hibernate requirement (swap >= RAM) with a small margin.
          # See flake-modules/disko.nix for why swap is its own
          # partition rather than a btrfs swapfile.
          swapSize = "32G";
        })
        # nixos-hardware: X1 Yoga 7th gen tunings — fprintd (fingerprint),
        # fwupd (firmware updates), Wacom pen/touch, SSD TRIM. Sets
        # boot.kernelPackages only if < 5.19 (conditional mkDefault, no
        # conflict with our explicit linuxPackages_latest below).
        inputs.nixos-hardware.nixosModules.lenovo-thinkpad-x1-yoga-7th-gen
      ]
      # Bare-metal graphical core: impermanence, backup, gpu, power,
      # networking, nix-settings, system-utils, users, fonts, locale,
      # battery, audio, bluetooth, boot, file-manager, login-ly, niri,
      # lockscreen, home-manager-bootstrap. See
      # flake-modules/bundles/nixos-workstation.nix.
      ++ config.flake.lib.bundles.nixos.workstation
      ++ [
        # ── pb-x1-specific extras ───────────────────────────────────
        # USB/serial/JTAG udev rules + device groups for the primary
        # user's PCB / firmware work.
        config.flake.modules.nixos.hardware-hacking
        # Fingerprint (Synaptics) + PAM stack reordering.
        config.flake.modules.nixos.biometrics
        # Face unlock — howdy + IR emitter + camera autodetect. Opt-in
        # companion to biometrics (~1.2 GiB howdy closure); pb-x1 has IR
        # hardware so it's wired here.
        config.flake.modules.nixos.face-unlock

        # NOT imported on pb-x1: the auto-deploy bundle (auto-upgrade,
        # nixos-clone, hm-auto-upgrade). This is the active dev box — a
        # 04:40 nixos-rebuild timer racing in-progress edits and a 05:30
        # `home-manager switch` from github: that blows away local HM
        # iteration are more annoying than useful. `sudo nixos-rebuild
        # switch --flake .#pb-x1` and `home-manager switch --flake
        # .#'p@pb-x1'` are the workflow here. To opt in later, append
        # `config.flake.lib.bundles.nixos.auto-deploy`.
      ];

      # Host identity + base packages + primary user.
      networking.hostName = hostName;
      users.primary = user;

      # GPU: Intel Iris Xe iGPU (Tiger Lake / Alder Lake on this
      # generation of X1 Yoga). See flake-modules/gpu.nix for what
      # this enables.
      gpu.driver = "intel";

      # Battery / hibernate config (declared as a NixOS module option
      # by flake-modules/battery.nix). Lenovo X1 Yoga supports kernel
      # charge thresholds via /sys/class/power_supply/BAT0/
      # charge_control_*_threshold. Capping at 80% extends battery
      # lifespan substantially. Set to 100 (and recharge to full)
      # before flying or other long unplug.
      #
      # Swap is provisioned by the disko factory above (swapSize =
      # "32G") as its own GPT partition; resumeDevice + the rest of
      # hibernate-resume wire themselves up via disko's swap content
      # type. No per-host resume_offset to maintain.
      battery = {
        chargeStopThreshold = 80;
        chargeStartThreshold = 75;
        # UPower CriticalAction at this percent. Hibernate requires a
        # swap area large enough for RAM. Falls back to PowerOff if
        # hibernate fails.
        criticalPercent = 10;
        criticalAction = "Hibernate";
      };

      # Bootloader policy lives in flake-modules/boot.nix (imported
      # above as config.flake.modules.nixos.boot). Override individual
      # systemd-boot settings here with mkForce if this host needs to
      # diverge.
      # kernelPackages = linuxPackages_latest comes from the workstation
      # bundle (flake-modules/kernel-latest.nix); override here if needed.

      # Primary user. initialPassword "changeme" — change on first login;
      # the new hash survives the impermanence wipe via the /etc/shadow
      # copy-sync. The old `input` group (idled-only) is dropped.
      users.users.${user} = config.flake.lib.mkUser {
        name = user;
        admin = true;
        extraGroups = [ "video" "audio" ];
        shell = hmPkgs.zsh;
      };

      # Base CLI (git/vim/curl/wget) is provided system-wide by
      # flake-modules/system-utils.nix; nothing host-specific to add.

      system.stateVersion = stateVersion;
    };
  };

  configurations.homeManager."${user}@${hostName}" = {
    pkgs = hmPkgs;
    module = {
      imports = config.flake.lib.bundles.homeManager.desktop ++ [
        # hardware-hacking HM tools (esptool, picocom, dfu-util, etc.)
        # moved out of the desktop bundle so m-pc (no NixOS udev rules,
        # no USB-device access for p) doesn't get them.
        config.flake.modules.homeManager.hardware-hacking
        # These three are opt-in per-host since 2026-05-16: the
        # desktop bundle no longer carries them (so vm-desktop / new
        # hosts don't pay the closures unless asked). pb-x1 does PCB
        # work + CAD + uses firefox as the daily driver, so restore
        # all three here.
        config.flake.modules.homeManager.kicad
        config.flake.modules.homeManager.freecad
        config.flake.modules.homeManager.firefox
      ];

      # HM manages itself.
      programs.home-manager.enable = true;

      # idle timings are module defaults now (idle.nix 300/420/900;
      # battery -> power-saver is power-profiles-daemon BatteryAware).

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

      # EDITOR/VISUAL default to "vim" via flake-modules/vim.nix.

      home.username = user;
      home.homeDirectory = "/home/${user}";
      home.stateVersion = stateVersion;
    };
  };
}
