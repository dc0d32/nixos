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

  # Shared per-host EasyEffects config — same for p, m, and s on this
  # host, so we factor it out of the three HM modules. Hand-tuned
  # presets for the T480's stock Realtek ALC257 + 2W down-firing
  # speakers. T480 is NOT a Dolby DAX3 licensed model, so unlike
  # pb-x1 there's no Lenovo driver to extract IRs from — the
  # corrections here are pure parametric EQ + safety limiter, no
  # convolver/IRS. See hosts/pb-t480/audio-presets/README.md for the
  # design notes.
  #
  # autoloads = [] until the actual T480 PipeWire sink node-name is
  # captured on real hardware. Run on the T480 itself, from a
  # checkout of this flake:
  #   ./scripts/host-setup.sh --audio-discover
  # which prints a ready-to-paste autoload entry like:
  #   {
  #     device = "alsa_output.pci-0000_00_1f.3.analog-stereo";
  #     profile = "analog-stereo";
  #     description = "...";
  #     preset = "T480-Music";
  #   }
  # Until then EasyEffects runs in passthrough; users can apply
  # T480-Music or T480-Voice by hand from the EE GUI to audition.
  audioCfg = {
    presetsDir = ../../hosts/pb-t480/audio-presets;
    # No IRS files — the presets don't reference convolver#0.
    # irsDir = ../../hosts/pb-t480/audio-irs;  # if/when measured
    autoloads = [ ];
  };

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

    # EasyEffects per-host data — shared with p on this host.
    audio = audioCfg;

    home.sessionVariables = {
      EDITOR = "vim";
      VISUAL = "vim";
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

  # NOTE: `audio.*` is set inside each HM module block below, NOT
  # here. audio.nix declares its options as HM module options
  # (per-HM-config) so multi-laptop hosts can each carry their own
  # presetsDir / irsDir / autoloads without singleton conflicts.
  # The shared per-host audio config is factored into the `audioCfg`
  # binding in the `let` block above.

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
  # Both kids share the same policy:
  #   - Window mon-thu + sun: 06:00-22:00. Sunday too because Monday
  #     is school — the curfew is "no use after 22:00 on the night
  #     BEFORE a school day."
  #   - Window fri + sat:     06:00-23:00. Looser cutoff because the
  #     next morning isn't school.
  #   - Budget mon-fri:       240 min (4h). All five are school days.
  #   - Budget sat + sun:     360 min (6h).
  #
  # Note Friday is a school day (4h budget) but Friday night curfew
  # is the looser 23:00 because Saturday isn't school. The two axes
  # are independent — that's the whole point of the *ByDay form.
  #
  # p is unrestricted (not listed in timekpr.users) but IS in the
  # `timekpr` group below so they can drive timekpra/timekprc to
  # grant ad-hoc time or change limits at runtime.
  timekpr.users =
    let
      kidPolicy = {
        allowedHoursByDay = {
          mon = "06:00-22:00";
          tue = "06:00-22:00";
          wed = "06:00-22:00";
          thu = "06:00-22:00";
          fri = "06:00-23:00";
          sat = "06:00-23:00";
          sun = "06:00-22:00";
        };
        dailyBudgetMinutesByDay = {
          mon = 240;
          tue = 240;
          wed = 240;
          thu = 240;
          fri = 240;
          sat = 360;
          sun = 360;
        };
      };
    in
    {
      m = kidPolicy;
      s = kidPolicy;
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
        #   - hardware-hacking (NixOS half: udev rules + dialout/plugdev/uucp
        #     group membership for `users.primary` = `p`. Kids' HM bundle
        #     does pull in the user-side hardware-hacking module — KiCad,
        #     esptool, picocom, lsusb — so they can do EDA and run the
        #     CLIs, but USB device access is gated on group membership
        #     they don't have. To let a kid actually flash a board on this
        #     machine they'd need to log in as `p` (or `p` would need to
        #     temporarily add them to dialout/plugdev).)
        config.flake.modules.nixos.gpu
        config.flake.modules.nixos.power
        config.flake.modules.nixos.networking
        config.flake.modules.nixos.nix-settings
        config.flake.modules.nixos.system-utils
        config.flake.modules.nixos.users
        config.flake.modules.nixos.fonts
        config.flake.modules.nixos.locale
        config.flake.modules.nixos.battery
        # Audio: PipeWire/ALSA/Pulse/RTKit + WirePlumber 100% volume
        # cap. No host-specific EasyEffects presets/IRS/autoloads
        # set yet for the T480 — the HM-side daemon launches in
        # passthrough mode (no preset loaded). Author T480 presets
        # later and wire them via `audio.presetsDir` /
        # `audio.autoloads` here.
        config.flake.modules.nixos.audio
        config.flake.modules.nixos.bluetooth
        config.flake.modules.nixos.boot
        config.flake.modules.nixos.file-manager
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

      # Bootloader policy lives in flake-modules/boot.nix (imported
      # above as config.flake.modules.nixos.boot). Override individual
      # systemd-boot settings here with mkForce if the real hardware
      # turns out to be BIOS/legacy and needs grub instead.
      boot.kernelPackages = hmPkgs.linuxPackages_latest;

      # All three accounts in one assignment (a single module-attrset
      # literal can't have two `users.users = …` entries).
      #   - p   : admin (wheel + networkmanager). Also in `timekpr`
      #           so they can drive `timekpra` to grant ad-hoc time
      #           or adjust per-kid policies at runtime.
      #   - m,s : kid (no wheel, no sudo). They get
      #           video/audio so the desktop session works,
      #           `input` so quickshell's lockscreen / idled function
      #           for them too (idled reads /dev/input/event*), and
      #           `networkmanager` so they can connect to any wifi
      #           AP themselves without an admin around — important
      #           because the laptop travels (school, friends'
      #           houses) and waiting for p to type a password
      #           breaks the "kids can self-serve on this machine"
      #           contract. NetworkManager group membership grants
      #           connect/disconnect/add-AP for kids; only system-
      #           wide config (e.g. dispatcher scripts, global
      #           settings) still needs wheel.
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
          extraGroups = [ "video" "audio" "input" "networkmanager" ];
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

          # EasyEffects per-host data — shared with kids on this host.
          audio = audioCfg;

          home.sessionVariables = {
            EDITOR = "vim";
            VISUAL = "vim";
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
