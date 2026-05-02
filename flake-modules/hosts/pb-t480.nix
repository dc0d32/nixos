# pb-t480 — shared family laptop with parental-control accounts.
#
# Hardware: Lenovo ThinkPad T480 (8th-gen Coffee Lake, x86_64).
# Naming follows the pb-x1 scheme: "pb" (initials) + "t480" (model).
#
# Three NixOS users:
#   - p : admin (wheel), full HM mirror of pb-x1
#   - m : kid (no wheel), restricted HM (no dev tooling)
#   - s : kid (no wheel), restricted HM (no dev tooling)
#
# Kids' graphical session is the same niri/quickshell stack as p so
# things look familiar across users. They get google-chrome (with
# Family-Link-locking managed policies — see chrome-managed.nix),
# alacritty, zsh but no vscode / freecad / bitwarden / ai-cli /
# build-deps. Web filtering and DNS logging are NOT installed
# (deferred per session notes 2026-04-30-family-laptop-host.md,
# written before the rename).
#
# Time-of-day / screen-time controls are wired via flake-modules/
# timekpr.nix using nixpkgs' `timekpr` package (= upstream timekpr-
# next). Per-kid policies are set in the `timekpr.users.*` block
# below. p is added to the `timekpr` group so they can drive
# `timekpra` / `timekprc` to make ad-hoc adjustments.
#
# Login activity is observable today via the systemd journal (logind
# session opened/closed events). The wrapper `family-activity` (defined
# below) is a convenience for p to grep the journal for m/s sessions.
#
# To rebuild on the actual hardware:
#   sudo nixos-rebuild switch --flake .#pb-t480
#
# HM activations run automatically on first boot via the
# home-manager-bootstrap module (one oneshot service per user). For
# subsequent updates, each user can run their own:
#   home-manager switch --flake .#'p@pb-t480'    # for p
#   home-manager switch --flake .#'m@pb-t480'    # for m
#   home-manager switch --flake .#'s@pb-t480'    # for s
#
# Retire when: this host is decommissioned or replaced by a successor
#   (e.g. pb-t14 / a different ThinkPad gen), OR split into separate
#   per-kid hosts, OR replaced by a proper multi-seat configuration.
{ lib, config, inputs, ... }:
let
  hostName = "pb-t480";
  primaryUser = "p";
  kidUsers = [ "m" "s" ];
  system = "x86_64-linux";
  stateVersion = "25.11";

  # HM pkgs instance shared by all three HM configs on this host.
  # Built via the shared factory in ../mk-pkgs.nix.
  hmPkgs = config.flake.lib.mkPkgs system;

  # Convenience wrapper for p to view kid-account login activity.
  # Reads from the systemd journal (which p can read via wheel
  # membership), filters logind session events for the kid users, and
  # pretty-prints them.
  familyActivity = hmPkgs.writeShellScriptBin "family-activity" ''
    set -eu
    days="''${1:-7}"
    echo "Kid session activity over the last $days days:"
    echo
    ${hmPkgs.systemd}/bin/journalctl \
      --since "$days days ago" \
      -u systemd-logind.service \
      --grep "session (opened|closed) for user (m|s)" \
      --output=short-iso \
      --no-pager
  '';

  # Per-kid home-manager module. Uses the `kid` bundle: minimal CLI,
  # google-chrome with Family-Link-locking managed policies (see
  # flake-modules/chrome-managed.nix), zoom for school, full
  # compositor stack, no dev tooling, no admin apps. `username`
  # parameterises the home.* fields below.
  mkKidHmModule = username: {
    imports = config.flake.lib.bundles.homeManager.kid;

    programs.home-manager.enable = true;

    # Auto-lock / DPMS / suspend timings (seconds). Tighter for kid
    # accounts — they leave sessions unattended more often. No
    # powerSaverPercent (default 0 = disabled): kids' charge
    # behavior isn't worth automating.
    idle = {
      lockAfter = 300;
      dpmsAfter = 420;
      suspendAfter = 900;
    };

    home.sessionVariables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
    };

    home.username = username;
    home.homeDirectory = "/home/${username}";
    home.stateVersion = stateVersion;
  };
in
{
  # ── Top-level option values supplied by this host ────────────────
  git = {
    name = "CHANGEME";
    email = "CHANGEME@example.com";
  };

  # GPU driver is a guess — revisit after generating real hardware-config.
  # T480 SKUs ship with Intel UHD 620 alone, or Intel + Nvidia MX150
  # Optimus. Today this module only knows intel/amd/nvidia/none — proper
  # PRIME/Optimus support is a follow-up commit once the real bus IDs
  # are known from `lspci -nn | grep -E 'VGA|3D'`.
  gpu.driver = "intel";

  locale = {
    timezone = "America/Los_Angeles";
    lang = "en_US.UTF-8";
  };

  # NOTE: `battery.*` is set inside `configurations.nixos.${hostName}.module`
  # below, NOT here — see the same note in pb-x1.nix.

  wallpaper = {
    intervalMinutes = 30;
  };

  # NOTE: `idle.*` is set inside each HM module block below, NOT
  # here — see the same note in pb-x1.nix.

  # Chrome managed-policy file applied to
  # /etc/opt/chrome/policies/managed/ on this host. See
  # flake-modules/chrome-managed.nix for why this exists and
  # hosts/pb-t480/chrome-policy.md for what each policy does.
  # NOTE: on Linux there is no per-user Chrome policy mechanism;
  # the policy applies to every user on this host who launches
  # google-chrome, including p. p has accepted that trade-off
  # because Family Link supervision (the whole point of the policy)
  # only works on signed-in Chrome with Google's API keys, which
  # the open-source Chromium build lacks.
  chrome-managed.policyFile = ../../hosts/pb-t480/chrome-policy.json;

  # ── Per-kid screen-time policies (timekpr) ───────────────────────
  # m: weekday 06:00-21:00 window, 4h/day budget.
  # s: weekday 07:00-22:00 window, 6h/day budget (older kid).
  # p is unrestricted (not listed in timekpr.users) but IS in the
  # `timekpr` group below so they can drive timekpra/timekprc.
  timekpr.users = {
    m = {
      allowedHours = "06:00-21:00";
      dailyBudgetMinutes = 240;
    };
    s = {
      allowedHours = "07:00-22:00";
      dailyBudgetMinutes = 360;
    };
  };

  # ── NixOS configuration ──────────────────────────────────────────
  configurations.nixos.${hostName} = {
    # placeholder = false: real hardware-configuration.nix has been
    # generated and committed (see hosts/pb-t480/hardware-configuration.nix).
    # `nix flake check` and `nixos-rebuild` no longer need
    # NIXOS_ALLOW_PLACEHOLDER=1 for this host.
    placeholder = false;
    module = {
      imports = [
        ../../hosts/pb-t480/hardware-configuration.nix

        # Hardware-specific defaults from nixos-hardware (kernel
        # modules, firmware, T480 quirks). Pulls in things like
        # thinkpad_acpi, microcode, sane TLP-vs-PPD defaults, etc.
        inputs.nixos-hardware.nixosModules.lenovo-thinkpad-t480

        # Feature modules. NOT importing:
        #   - audio (X1-Yoga-specific presets; no T480 preset authored yet)
        #   - hardware-hacking (kids don't need dialout/plugdev)
        config.flake.modules.nixos.gpu
        config.flake.modules.nixos.power
        config.flake.modules.nixos.networking
        config.flake.modules.nixos.nix-settings
        config.flake.modules.nixos.system-utils
        config.flake.modules.nixos.users
        config.flake.modules.nixos.fonts
        config.flake.modules.nixos.locale
        config.flake.modules.nixos.battery
        config.flake.modules.nixos.bluetooth
        config.flake.modules.nixos.login-ly
        # Fingerprint (Synaptics) + face auth (howdy via IR camera)
        # + PAM stack reordering. The IR camera path is autodetected
        # at boot by howdy-camera-autodetect; the static fallback
        # /dev/video2 only matters before that service runs.
        config.flake.modules.nixos.biometrics
        config.flake.modules.nixos.niri
        config.flake.modules.nixos.timekpr
        config.flake.modules.nixos.chrome-managed
        # Auto-bootstraps each user's home-manager profile on first
        # boot via a oneshot systemd service per HM config matching
        # `*@pb-t480`. Removes the post-install
        # `home-manager switch --flake .#'<user>@pb-t480'` step for
        # p, m, and s.
        config.flake.modules.nixos.home-manager-bootstrap
        # Steam (system-wide programs.steam.enable). Game/store/chat
        # restrictions are configured per-Steam-account in Steam's
        # built-in Family View, not here. See flake-modules/steam.nix.
        config.flake.modules.nixos.steam
      ];

      networking.hostName = hostName;
      users.primary = primaryUser;
      console.keyMap = "us";

      # Battery / hibernate config (declared as a NixOS module option
      # by flake-modules/battery.nix). T480 has BAT0 (external
      # swappable, primary) and BAT1 (internal). Both get the same
      # charge thresholds — capping BAT1 at 80% costs nothing and
      # extends its lifespan alongside BAT0.
      #
      # resumeDevice is the btrfs root UUID (the swapfile lives on
      # the root subvol's parent fs). After first hibernate cycle on
      # real hardware, capture `resume_offset=NNN` from
      #   journalctl -u battery-resume-offset
      # and add it to boot.kernelParams below (currently the
      # placeholder `resume_offset=0` value).
      battery = {
        batteries = [ "BAT0" "BAT1" ];
        chargeStopThreshold = 80;
        chargeStartThreshold = 75;
        criticalPercent = 10;
        criticalAction = "Hibernate";
        powerSaverPercent = 40;
        swapSizeGiB = 32;
        resumeDevice = "/dev/disk/by-uuid/26b43411-b5dc-406f-a737-9205fbd21732";
      };

      # Bootloader: standard UEFI boot. Override if the real hardware
      # is BIOS/legacy.
      boot.loader.systemd-boot.enable = lib.mkDefault true;
      boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
      boot.kernelPackages = hmPkgs.linuxPackages_latest;

      # All three accounts in one assignment (a single module-attrset
      # literal can't have two `users.users = …` entries).
      #   - p   : admin (wheel + networkmanager). Also in `timekpr`
      #           so they can drive `timekpra` to grant ad-hoc time
      #           or adjust per-kid policies at runtime.
      #   - m,s : kid (no wheel, no networkmanager). They get
      #           video/audio so the desktop session works, and
      #           `input` so quickshell's lockscreen / idled function
      #           for them too (idled reads /dev/input/event*).
      #
      # Initial passwords are throwaway literals (`changeme`); rotate them
      # with `passwd` on first login.
      users.users =
        {
          ${primaryUser} = {
            isNormalUser = true;
            description = primaryUser;
            extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" "timekpr" ];
            shell = hmPkgs.zsh;
            # Throwaway initial password; change with `passwd` on first login.
            initialPassword = "changeme";
          };
        }
        // lib.genAttrs kidUsers (kid: {
          isNormalUser = true;
          description = kid;
          extraGroups = [ "video" "audio" "input" ];
          shell = hmPkgs.zsh;
          initialPassword = "changeme";
        });

      # System packages: minimal set + the kid-activity wrapper for p.
      environment.systemPackages = with hmPkgs; [
        git
        vim
        curl
        wget
        familyActivity
      ];

      system.stateVersion = stateVersion;
    };
  };

  # ── Home-manager configurations: one for p, one per kid. ────────
  # All three configs assembled into a single attrset to avoid
  # multiple-assignment conflicts on the `configurations.homeManager`
  # option. `p` gets the full pb-x1 HM mirror; kids get the restricted
  # set built by `mkKidHmModule`.
  configurations.homeManager =
    {
      "${primaryUser}@${hostName}" = {
        pkgs = hmPkgs;
        module = {
          imports = config.flake.lib.bundles.homeManager.desktop;

          programs.home-manager.enable = true;

          # Auto-lock / DPMS / suspend timings (seconds), plus the
          # power-saver-percent threshold mirrored from battery on
          # the NixOS side (40% — see battery block in the NixOS
          # module above). Same values as pb-x1.
          idle = {
            lockAfter = 300;
            dpmsAfter = 420;
            suspendAfter = 900;
            powerSaverPercent = 40;
          };

          home.sessionVariables = {
            EDITOR = "nvim";
            VISUAL = "nvim";
          };

          home.username = primaryUser;
          home.homeDirectory = "/home/${primaryUser}";
          home.stateVersion = stateVersion;
        };
      };
    }
    // builtins.listToAttrs (map
      (kid: {
        name = "${kid}@${hostName}";
        value = {
          pkgs = hmPkgs;
          module = mkKidHmModule kid;
        };
      })
      kidUsers);
}
