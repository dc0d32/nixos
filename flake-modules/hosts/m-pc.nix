# m-pc — Compaq Pro 4300 SFF, kid desktop for `m`.
#
# Hardware: HP/Compaq Pro 4300 Small Form Factor (3rd-gen Ivy Bridge
# era, 2012-2013), Intel Core i3 + 8 GiB RAM, AMD Radeon Pro WX 2100
# discrete GPU (low-profile workstation card, GCN 1.1 / "Tonga",
# originally branded "FirePro W2100" before AMD's 2017 Radeon Pro
# rebrand — same silicon, same driver path; some places in the
# downstream tooling still call it FirePro). Driven by amdgpu in
# mainline kernels. x86_64-linux. No battery (desktop), no
# fingerprint reader, no IR camera. Built-in chassis speaker wired
# through the motherboard HD-audio codec — appears as a PipeWire
# sink alongside any external speakers / headphones.
#
# Two NixOS users:
#   - p : admin (wheel + timekpr group), full HM mirror of pb-x1's
#         desktop bundle. Same shell / browsers / dev tooling so
#         logging in as p on m-pc feels identical to logging in as p
#         on pb-x1 / pb-t480.
#   - m : kid (no wheel), restricted HM. Uses the `kid` bundle
#         (chrome with Family-Link-locking managed policies, zoom,
#         freecad, no dev tooling). Mirrors what `m` already gets on
#         pb-t480 so the two hosts feel identical to her.
#
# Why a desktop in the family fleet:
#   The kids' shared T480 (pb-t480) travels with them; m-pc is a
#   permanently-positioned workstation in m's room with a real
#   keyboard / mouse / monitor. Having a fixed desk station means m
#   can leave a project (FreeCAD model, Chrome tabs, in-progress
#   homework) open across days without packing up a laptop.
#
# Why the AMD Radeon Pro WX 2100 instead of the integrated HD 2500:
#   The WX 2100 has 2 GiB of dedicated VRAM and 4 mini-DisplayPort
#   outputs (vs the integrated chip's 1 DP + 1 VGA and shared system
#   RAM). FreeCAD and a single Chrome instance with five tabs are
#   already more than the HD 2500 wants to push at native resolution
#   on a modern compositor. The WX 2100 is also still supported by
#   amdgpu in current kernels (GCN 1.1, "Tonga"); when that drops,
#   the host falls back to radeon (also still mainline as of 2026).
#
# Chrome managed policy:
#   We reuse hosts/pb-t480/chrome-policy.json directly rather than
#   maintaining a parallel copy here. The policy is identical (same
#   kid, same Family Link supervision) and a divergent copy would
#   inevitably drift. If/when m-pc needs to differ (e.g. unblock a
#   single extension only on the desktop), copy the file into
#   hosts/m-pc/chrome-policy.json and flip the reference below.
#
# Timekpr screen-time:
#   Same per-day window + budget as pb-t480. The two hosts each enforce
#   their own limit independently — there is no shared cross-host
#   budget yet (timekpr-next does not support that). An honest
#   description of the policy: "up to N hours on EACH host per day"
#   rather than "N hours total." If/when the kids start gaming
#   sessions across both, this becomes worth solving (probably via a
#   syncthing-backed shared timekpr state file or a cross-host
#   accounting daemon); for now it's an acceptable approximation.
#
# Hibernate on a desktop:
#   Unusual but explicitly requested. battery.nix is imported (the
#   charge-threshold writes are harmless `tmpfiles w+` no-ops on a
#   battery-less host because the sysfs files don't exist), giving us
#   the UPower hibernate-on-critical wiring. The actual swap area
#   comes from the disko factory's `swapSize = "12G"` (RAM is 8 GiB,
#   12 GiB clears the swap >= RAM requirement with margin). UPower's
#   PercentageCritical action wires up but never fires (no battery to
#   drain), so hibernate on m-pc is purely user-initiated via
#   `systemctl hibernate`.
#
# To rebuild on the actual hardware (after regenerating
# hardware-configuration.nix):
#   sudo nixos-rebuild switch --flake .#m-pc
#
# HM activations run automatically on first boot via the
# home-manager-bootstrap module (one oneshot service per user). For
# subsequent updates, each user can run their own:
#   home-manager switch --flake .#'p@m-pc'    # for p
#   home-manager switch --flake .#'m@m-pc'    # for m
#
# Retire when: this host is decommissioned, replaced by a successor
#   (e.g. a different desktop chassis), OR converges with another
#   host bridge to the point where one module can serve both.
{ lib, config, ... }:
let
  hostName = "m-pc";
  primaryUser = "p";
  kidUsers = [ "m" ];
  system = "x86_64-linux";
  stateVersion = "25.11";

  # HM pkgs instance shared by both HM configs on this host. Built via
  # the shared factory in ../mk-pkgs.nix.
  hmPkgs = config.flake.lib.mkPkgs system;

  # Shared per-host EasyEffects config. The Compaq 4300 SFF has stock
  # Realtek HD audio driving (a) the built-in chassis speaker, (b) the
  # rear 3.5mm line-out, and (c) any HDMI/DisplayPort audio routed
  # through the WX 2100. PipeWire enumerates each as its own sink with
  # no extra config, so the user (or EasyEffects autoload) picks
  # which one is default. We don't ship speaker-correction presets
  # for any of them yet, so EasyEffects runs in passthrough.
  # presetsDir / irsDir / autoloads are left at their defaults
  # (null / null / []); EasyEffects launches with a clean slate. To
  # author a preset later, drop it under hosts/m-pc/audio-presets/,
  # point presetsDir at that path, and add an autoloads entry keyed
  # on the desired sink's PipeWire node-name (capture with
  # `wpctl inspect @DEFAULT_AUDIO_SINK@ | grep node.name`).
  audioCfg = {
    presetsDir = null;
    irsDir = null;
    autoloads = [ ];
  };

  # Per-kid home-manager module. Identical shape to pb-t480's kid HM
  # module (uses the `kid` bundle: chrome+managed, zoom, freecad,
  # compositor stack, no dev tooling). Parameterised by username so
  # the same factory can produce more kid HM configs later without
  # change.
  mkKidHmModule = username: {
    imports = config.flake.lib.bundles.homeManager.kid ++ [
      # FreeCAD is opt-in per-host since 2026-05-16; the kid bundle
      # no longer carries it. Kids on m-pc had it before, so preserve
      # that here.
      config.flake.modules.homeManager.freecad
    ];

    programs.home-manager.enable = true;
    # pb-t480 kids — m's muscle memory across the two hosts shouldn't
    # diverge. No powerSaverPercent: there's no battery to monitor.
    idle = {
      lockAfter = 300;
      dpmsAfter = 420;
      suspendAfter = 900;
    };

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

  # NOTE: `gpu.driver` is set inside `configurations.nixos.${hostName}.module`
  # below, NOT here — see the same note in pb-x1.nix.

  locale = {
    timezone = "America/Los_Angeles";
    lang = "en_US.UTF-8";
  };

  # NOTE: `battery.*` is set inside `configurations.nixos.${hostName}.module`
  # below, NOT here — see the same note in pb-x1.nix. Even though this is
  # a desktop, we import battery.nix for the UPower hibernate-on-critical
  # plumbing (the battery-specific tmpfiles are harmless no-ops on a
  # battery-less host).

  # NOTE: `audio.*` is set inside each HM module block below, NOT here.
  # Per-HM-config option scoping; same reasoning as pb-t480.

  wallpaper = {
    intervalMinutes = 30;
  };

  # NOTE: `idle.*` is set inside each HM module block below, NOT here.

  # Reuse the same Family-Link-locking managed-policy file as pb-t480
  # rather than duplicating it. Both hosts apply the same restrictions
  # to the same kid; a divergent copy would drift. Switch this to
  # ../../hosts/m-pc/chrome-policy.json if/when m-pc needs to differ.
  chrome-managed.policyFile = ../../hosts/pb-t480/chrome-policy.json;

  # ── Per-kid screen-time policies (timekpr) ───────────────────────
  # Identical policy to pb-t480 (same kid, same school schedule). See
  # the long comment in pb-t480.nix's `timekpr.users` block for the
  # weekday vs weekend rationale and the school-night curfew design.
  #
  # Cross-host accounting caveat: timekpr enforces this budget
  # PER HOST. m can spend the full daily allotment on m-pc AND another
  # full daily allotment on pb-t480 if she switches between them. Not
  # great, but not worth solving today; revisit if/when m starts
  # actually exploiting it.
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
    };

  # ── NixOS configuration ──────────────────────────────────────────
  configurations.nixos.${hostName} = {
    # placeholder = true: hosts/m-pc/hardware-configuration.nix is the
    # all-zeros sentinel until nixos-generate-config is run on the real
    # machine. Skips the auto `nix flake check` entry so pure
    # `nix flake check` passes on the dev box; smoke-build with
    # NIXOS_ALLOW_PLACEHOLDER=1 nix build --impure
    #   .#nixosConfigurations.m-pc.config.system.build.toplevel
    placeholder = true;
    module = {
      imports = [
        ../../hosts/m-pc/hardware-configuration.nix

        # Disko: declarative disk layout. Bare-metal layout includes
        # a 1 MiB bios-boot partition so grub installs cleanly on
        # this BIOS-era Compaq SFF (no UEFI firmware). /dev/sda is
        # the onboard SATA SSD.
        config.flake.modules.nixos.disko
        (config.flake.lib.diskoLayouts.bare-metal {
          disk = "/dev/sda";
          # 12 GiB swap partition — m-pc has 8 GiB RAM; 12 GiB clears
          # the hibernate requirement (swap >= RAM) with margin for
          # zswap-style compression headroom.
          swapSize = "12G";
        })

        # Feature modules. Subset of pb-t480 with biometrics +
        # hardware-hacking dropped (no fingerprint/IR on this box;
        # m's robotics work happens on pb-t480, not here).
        config.flake.modules.nixos.gpu
        config.flake.modules.nixos.power
        config.flake.modules.nixos.networking
        config.flake.modules.nixos.nix-settings
        config.flake.modules.nixos.system-utils
        config.flake.modules.nixos.users
        config.flake.modules.nixos.fonts
        config.flake.modules.nixos.locale
        # battery.nix imported even on this desktop — it provides the
        # UPower hibernate-on-critical wiring we want. The
        # battery-threshold writes are harmless no-ops where
        # /sys/class/power_supply/BAT0 doesn't exist (tmpfiles `w+`
        # ignores ENOENT). The swap partition is provisioned by the
        # disko factory above.
        config.flake.modules.nixos.battery
        config.flake.modules.nixos.audio
        config.flake.modules.nixos.bluetooth
        config.flake.modules.nixos.boot
        config.flake.modules.nixos.file-manager
        config.flake.modules.nixos.login-ly
        config.flake.modules.nixos.niri
        # Quickshell system-side wiring: security.pam.services.
        # quickshell-password. m-pc deliberately does NOT import the
        # biometrics module (no fingerprint reader, no IR camera) but
        # still runs the lockscreen — it needs the password PAM
        # service. The companion biometric PAM service lives in
        # biometrics.nix and is intentionally absent here;
        # LockContext.qml gates its biometric PamContext on
        # QUICKSHELL_LOCK_FACE / QUICKSHELL_LOCK_FINGERPRINT (set
        # from biometrics.enable, which stays false here) so the
        # missing service is never referenced.
        config.flake.modules.nixos.quickshell
        config.flake.modules.nixos.timekpr
        config.flake.modules.nixos.chrome-managed
        # Daily `nixos-rebuild switch --refresh --flake
        # github:dc0d32/nixos` at 04:40 local with 30min jitter, no
        # reboot. See flake-modules/auto-upgrade.nix.
        config.flake.modules.nixos.auto-upgrade
        # Auto-bootstraps each user's HM profile on first boot. One
        # oneshot service per HM config matching `*@m-pc`. Removes
        # the post-install `home-manager switch` step for p and m.
        config.flake.modules.nixos.home-manager-bootstrap
        # Per-user oneshot that clones https://github.com/dc0d32/nixos
        # into ~/nixos for each HM user (idempotent; backfills hosts
        # installed before host-setup.sh's install-time clone step).
        # See flake-modules/nixos-clone.nix.
        config.flake.modules.nixos.nixos-clone
        # Daily `home-manager switch` at 05:30 local for every HM
        # user on this host. Pulls fresh from github:dc0d32/nixos
        # each run. See flake-modules/hm-auto-upgrade.nix.
        config.flake.modules.nixos.hm-auto-upgrade
        # Steam (system-wide programs.steam.enable). Restrictions
        # (game/store/chat) are configured per-Steam-account in
        # Steam's built-in Family View, not here. The WX 2100 is
        # GCN 1.1 with 2 GiB VRAM — fine for older / lighter games
        # via Vulkan/RADV, won't push modern AAA.
        config.flake.modules.nixos.steam
      ];

      networking.hostName = hostName;
      users.primary = primaryUser;
      console.keyMap = "us";

      # AMD Radeon Pro WX 2100 (GCN 1.1 / "Tonga") is driven by amdgpu
      # in mainline kernels. RADV (the Mesa Vulkan driver) supports
      # GCN 1.1. The gpu module's `amd` branch wires up
      # services.xserver.videoDrivers = [ "amdgpu" ].
      gpu.driver = "amd";

      # battery.nix imported even though this is a desktop — we use
      # it for the UPower hibernate-on-critical wiring. Swap is
      # provisioned by the disko factory above (swapSize = "12G");
      # disko sets boot.resumeDevice to the swap partition
      # automatically. The desktop-irrelevant battery knobs
      # (chargeStop/Start/criticalPercent) keep their module
      # defaults; they no-op on this host because there are no
      # battery sysfs files to write to.
      # battery = { ... }; — module defaults are fine here, nothing
      # to override per-host.

      # Bootloader policy lives in flake-modules/boot.nix (imported
      # above as config.flake.modules.nixos.boot). The Compaq 4300 SFF
      # generation typically ships BIOS-only — if systemd-boot fails
      # on real hardware, override here:
      #   boot.loader.systemd-boot.enable = lib.mkForce false;
      #   boot.loader.grub = { enable = true; device = "/dev/sda"; };
      boot.kernelPackages = hmPkgs.linuxPackages_latest;

      # Both accounts in one assignment.
      #   - p : admin (wheel + networkmanager). In `timekpr` so they
      #         can drive `timekpra` / `timekprc` to grant ad-hoc
      #         time or adjust m's policy at runtime without sudo.
      #   - m : kid (no wheel, no sudo). video/audio for the desktop
      #         session, `input` for quickshell's lockscreen / idled,
      #         `networkmanager` so she can join APs herself if/when
      #         the wired connection is unavailable.
      #
      # Initial passwords are throwaway literals (`changeme`); rotate
      # them with `passwd` on first login.
      users.users =
        {
          ${primaryUser} = {
            isNormalUser = true;
            description = primaryUser;
            extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" "timekpr" ];
            shell = hmPkgs.zsh;
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

      # Minimal system package set; rest lives in home-manager.
      environment.systemPackages = with hmPkgs; [
        git
        vim
        curl
        wget
      ];

      system.stateVersion = stateVersion;
    };
  };

  # ── Home-manager configurations: one for p, one for m. ───────────
  configurations.homeManager =
    {
      "${primaryUser}@${hostName}" = {
        pkgs = hmPkgs;
        module = {
          imports = config.flake.lib.bundles.homeManager.desktop ++ [
            # KiCad + FreeCAD + Firefox are opt-in per-host since
            # 2026-05-16; preserve the previous behaviour for
            # m-pc's primary user.
            config.flake.modules.homeManager.kicad
            config.flake.modules.homeManager.freecad
            config.flake.modules.homeManager.firefox
          ];

          programs.home-manager.enable = true;

          # Auto-lock / DPMS / suspend timings (seconds). Same as
          # pb-x1 / pb-t480 to keep p's experience uniform across
          # hosts. No powerSaverPercent: no battery to monitor.
          idle = {
            lockAfter = 300;
            dpmsAfter = 420;
            suspendAfter = 900;
          };

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
