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
#   - m : kid (no wheel), restricted GUI HM. Uses the `kid` bundle
#         (chrome with Family-Link-locking managed policies, zoom,
#         freecad, plus full terminal dev/AI tooling). Mirrors what
#         `m` already gets on pb-t480 so the two hosts feel identical
#         to her.
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
#   Same per-day window + budget as pb-t480, and since 2026-07-27 the two
#   hosts share ONE daily pool rather than each enforcing its own copy.
#   The local timekpr daemon is still the only thing that enforces; the
#   cross-host accounting lives on ursa (flake-modules/timekpr-central.nix)
#   and `timekpr-sync` below reconciles this host against it every minute.
#   So the policy is honestly "N hours total per day across both machines",
#   not "N hours on EACH". If the controller is unreachable the agent
#   no-ops and this host falls back to its own local cap — the old
#   per-host behaviour, which is a safe degradation rather than an outage.
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
  central = config.flake.lib.timekprCentral;
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
in
{
  # ── Top-level option values supplied by this host ────────────────
  # git identity, locale/timezone and wallpaper interval use their module
  # defaults now (git.nix, locale.nix, wallpaper.nix). Nothing to set.

  # NOTE: `gpu.driver` is set inside `configurations.nixos.${hostName}.module`
  # below, NOT here — see the same note in pb-x1.nix.

  # NOTE: `battery.*` is set inside `configurations.nixos.${hostName}.module`
  # below, NOT here — see the same note in pb-x1.nix. Even though this is
  # a desktop, we import battery.nix for the UPower hibernate-on-critical
  # plumbing (the battery-specific tmpfiles are harmless no-ops on a
  # battery-less host).

  # NOTE: `audio.*` is set inside each HM module block below, NOT here.
  # Per-HM-config option scoping; same reasoning as pb-t480.

  # NOTE: `idle.*` is set inside each HM module block below, NOT here.

  # NOTE: `chrome-managed.*`, `timekpr.*` and `timekpr-sync.*` are set
  # inside `configurations.nixos.${hostName}.module`, for the same
  # per-config scoping reason.

  # ── NixOS configuration ──────────────────────────────────────────
  configurations.nixos.${hostName} = {
    # placeholder = false: hosts/m-pc/hardware-configuration.nix is a real
    # generated config (Intel desktop: ehci_pci/ahci/usb_storage), not the
    # all-zeros sentinel — the machine is a daily driver. The stale
    # `placeholder = true` here forced NIXOS_ALLOW_PLACEHOLDER=1 on every
    # rebuild of a live host and made the flake look like m-pc was never
    # installed. Corrected 2026-07-28.
    placeholder = false;
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
      ]
      # Bare-metal graphical core (impermanence + backup + gpu + power +
      # networking + nix-settings + system-utils + users + fonts + locale
      # + battery + audio + bluetooth + boot + file-manager + login-ly +
      # niri + lockscreen + home-manager-bootstrap). See
      # flake-modules/bundles/nixos-workstation.nix. battery is in the
      # core: on this battery-less desktop the charge-threshold writes are
      # harmless no-ops (tmpfiles `w+` ignores ENOENT) but we keep the
      # UPower hibernate-on-critical wiring. The lockscreen runs
      # password-only here because no biometrics module is imported.
      ++ config.flake.lib.bundles.nixos.workstation
      # Daily auto-pull from origin/main (this is a deployed-and-left
      # box). See flake-modules/bundles/nixos-auto-deploy.nix.
      ++ config.flake.lib.bundles.nixos.auto-deploy
      ++ [
        # ── m-pc-specific extras ────────────────────────────────────
        # Screen-time enforcement + Family-Link-locking Chrome policy
        # for the kid account. biometrics/face-unlock/hardware-hacking
        # are dropped (no fingerprint/IR on this box; m's robotics work
        # is on pb-t480). (The steam module was deleted 2026-06-25.)
        config.flake.modules.nixos.timekpr
        # Cross-host shared-budget agent — reports usage to the central
        # control plane and applies the shared remaining. See
        # flake-modules/timekpr-sync.nix.
        config.flake.modules.nixos.timekpr-sync
        config.flake.modules.nixos.chrome-managed
      ];

      networking.hostName = hostName;
      users.primary = primaryUser;

      # Reuse the same Family-Link-locking managed-policy file as pb-t480
      # rather than duplicating it. Both hosts apply the same restrictions
      # to the same kid; a divergent copy would drift. Switch this to
      # ../../hosts/m-pc/chrome-policy.json if/when m-pc needs to differ —
      # which is now actually possible, see flake-modules/chrome-managed.nix.
      chrome-managed.policyFile = ../../hosts/pb-t480/chrome-policy.json;

      # ── Per-kid screen-time policies (timekpr) ───────────────────────
      # Identical policy to pb-t480 (same kid, same school schedule). See
      # the long comment in pb-t480.nix's `timekpr.users` block for the
      # weekday vs weekend rationale and the school-night curfew design.
      #
      # This renders the LOCAL cap. The cross-host pool that keeps m from
      # spending it once here and once on pb-t480 is the `timekpr-sync`
      # block below.
      timekpr.users = lib.genAttrs kidUsers (_: config.flake.lib.kidTimekprPolicy);

      # Keep the admin account out of timekpr's sight entirely. Without
      # this, logging in as `p` here enrolls it and auto-writes an
      # unrestricted timekpr.p.conf — not limited, but tracked, and one
      # timekpra mis-click from locking the admin out of this machine.
      timekpr.excludeUsers = [ primaryUser ];

      # Shared cross-host daily budget. This host reports the seconds m
      # burns HERE to the controller on ursa and pulls back the pool-wide
      # remainder, so the budget rendered by `timekpr.users` above is
      # spent once per day across the whole fleet rather than once per
      # machine. Same pool as pb-t480 — that is the entire point. See
      # flake-modules/timekpr-sync.nix. Public hostname rather than the LAN
      # IP: it resolves from any VLAN via the AdGuard rewrite and rides a
      # real wildcard cert, so a forged controller can't hand out time.
      timekpr-sync = {
        serverUrl = central.url;
        users = kidUsers;
        token = central.reportToken;
      };

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
      # kernelPackages = linuxPackages_latest comes from the workstation
      # bundle (flake-modules/kernel-latest.nix).

      # Accounts (mkUser adds networkmanager; admin adds wheel).
      # initialPassword "changeme" — change on first login; survives the
      # impermanence wipe via the /etc/shadow copy-sync.
      #   - p : admin + timekpr (can grant ad-hoc time at runtime).
      #   - m : kid (no wheel).
      users.users =
        {
          ${primaryUser} = config.flake.lib.mkUser {
            name = primaryUser;
            admin = true;
            extraGroups = [ "video" "audio" "timekpr" ];
            shell = hmPkgs.zsh;
          };
        }
        // lib.genAttrs kidUsers (kid: config.flake.lib.mkUser {
          name = kid;
          extraGroups = [ "video" "audio" ];
          shell = hmPkgs.zsh;
        });

      # Base CLI (git/vim/curl/wget) comes from system-utils.nix.

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

          # idle timings and EDITOR/VISUAL are module defaults now
          # (idle.nix 300/420/900, vim.nix "vim").
          audio = audioCfg;

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
          module = config.flake.lib.mkKidHmModule { username = kid; audio = audioCfg; };
        };
      })
      kidUsers);
}
