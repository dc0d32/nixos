# family-laptop — shared family laptop with parental-control accounts.
#
# Three NixOS users:
#   - p : admin (wheel), full HM mirror of pb-x1
#   - m : kid (no wheel), restricted HM (no dev tooling)
#   - s : kid (no wheel), restricted HM (no dev tooling)
#
# Kids' graphical session is the same niri/quickshell stack as p so
# things look familiar across users. They get chrome, alacritty, zsh
# but no vscode / freecad / bitwarden / ai-cli / build-deps. Web
# filtering and DNS logging are NOT installed (deferred per session
# notes 2026-04-30-family-laptop-host.md).
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
# Naming: `family-laptop` is intentionally generic because the actual
# hardware model isn't decided yet. Rename to `<initials>-<model>` (per
# the pb-x1 scheme) once the box is chosen and built out.
#
# To rebuild on the actual hardware:
#   sudo nixos-rebuild switch --flake .#family-laptop
#   home-manager switch --flake .#'p@family-laptop'    # for p
#   home-manager switch --flake .#'m@family-laptop'    # for m
#   home-manager switch --flake .#'s@family-laptop'    # for s
#
# Retire when: split into separate per-kid hosts, or replaced by a
# proper multi-seat configuration.
{ inputs, lib, config, ... }:
let
  hostName = "family-laptop";
  primaryUser = "p";
  kidUsers = [ "m" "s" ];
  system = "x86_64-linux";
  stateVersion = "25.11";

  # HM pkgs instance shared by all three HM configs on this host.
  hmPkgs = import inputs.nixpkgs {
    inherit system;
    overlays = import ../../overlays;
    config = {
      allowUnfree = true;
      allowAliases = false;
    };
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

  # Per-kid home-manager module. Same desktop session as p (so the box
  # looks the same regardless of who's logged in) but no dev tooling
  # and no admin apps. `username` parameterises the imports.
  mkKidHmModule = username: {
    imports = [
      # Shell + terminal + browser. Kids get chromium-managed
      # (Family-Link-aware policy lockdown) instead of chrome,
      # because Linux has no per-user policy mechanism so the only
      # way to scope policies to the kids is to give them a
      # different browser binary. See flake-modules/chromium-managed.nix.
      config.flake.modules.homeManager.zsh
      config.flake.modules.homeManager.alacritty
      config.flake.modules.homeManager.chromium-managed
      config.flake.modules.homeManager.fonts

      # Desktop session (compositor + bar/lockscreen + auto-lock + wallpaper)
      config.flake.modules.homeManager.niri
      config.flake.modules.homeManager.quickshell
      config.flake.modules.homeManager.wallpaper
      config.flake.modules.homeManager.idle
      config.flake.modules.homeManager.polkit-agent
      config.flake.modules.homeManager.desktop-extras

      # Light extras
      config.flake.modules.homeManager.btop
      config.flake.modules.homeManager.neovim
    ];

    programs.home-manager.enable = true;

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

  # ── Secrets (sops-nix) — opt-in ─────────────────────────────────
  # Uncomment after running the bootstrap in secrets/README.md.
  # The 3 user password hashes (p, m, s) live in secrets/family-laptop.yaml
  # under keys users_p_password_hash, users_m_password_hash, users_s_password_hash.
  # secrets = {
  #   ageKeyFile       = "/home/${primaryUser}/.config/sops/age/keys.txt";
  #   systemAgeKeyFile = "/var/lib/sops-nix/key.txt";
  #   commonFile       = ../../secrets/common.yaml;
  #   hostFile         = ../../secrets/family-laptop.yaml;
  # };

  # GPU driver is a guess — revisit after generating real hardware-config.
  gpu.driver = "intel";

  locale = {
    timezone = "America/Los_Angeles";
    lang = "en_US.UTF-8";
  };

  wallpaper = {
    intervalMinutes = 30;
  };

  # Chromium managed-policy file applied to /etc/chromium/policies/
  # managed/ on this host. See flake-modules/chromium-managed.nix
  # for why this exists and hosts/family-laptop/chromium-policy.md
  # for what each policy does.
  chromium-managed.policyFile = ../../hosts/family-laptop/chromium-policy.json;

  # Auto-lock / DPMS / suspend timings (seconds).
  idle = {
    lockAfter = 300;
    dpmsAfter = 420;
    suspendAfter = 900;
  };

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
    module = {
      imports = [
        ../../hosts/family-laptop/hardware-configuration.nix

        # Feature modules. NOT importing:
        #   - audio (X1-Yoga-specific presets; no presets for this host yet)
        #   - battery (hardware-specific; hwconfig isn't real yet)
        #   - hardware-hacking (kids don't need dialout/plugdev)
        #   - biometrics (no fingerprint reader assumed; revisit after hwconfig)
        config.flake.modules.nixos.gpu
        config.flake.modules.nixos.power
        config.flake.modules.nixos.networking
        config.flake.modules.nixos.nix-settings
        config.flake.modules.nixos.system-utils
        config.flake.modules.nixos.users
        config.flake.modules.nixos.fonts
        config.flake.modules.nixos.locale
        config.flake.modules.nixos.login-ly
        config.flake.modules.nixos.niri
        config.flake.modules.nixos.timekpr
        config.flake.modules.nixos.chromium-managed
        # ── Secrets (sops-nix) ──
        # Uncomment after bootstrap (see secrets/README.md):
        # config.flake.modules.nixos.secrets
      ];

      networking.hostName = hostName;
      users.primary = primaryUser;
      console.keyMap = "us";

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
      # with `passwd` on first login. Once secrets are bootstrapped (see
      # secrets/README.md), replace each `initialPassword = "changeme"` with:
      #   hashedPasswordFile = config.sops.secrets.users_${user}_password_hash.path;
      # and declare the secrets in this module:
      #   sops.secrets = {
      #     users_p_password_hash = { neededForUsers = true; };
      #     users_m_password_hash = { neededForUsers = true; };
      #     users_s_password_hash = { neededForUsers = true; };
      #   };
      # `neededForUsers` puts the secret at /run/secrets-for-users/, which is
      # available before the user-creation activation script runs.
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
          imports = [
            config.flake.modules.homeManager.git
            config.flake.modules.homeManager.tmux
            config.flake.modules.homeManager.direnv
            config.flake.modules.homeManager.fonts
            config.flake.modules.homeManager.btop
            config.flake.modules.homeManager.build-deps
            config.flake.modules.homeManager.gh
            config.flake.modules.homeManager.ai-cli
            config.flake.modules.homeManager.hardware-hacking
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

          programs.home-manager.enable = true;

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
