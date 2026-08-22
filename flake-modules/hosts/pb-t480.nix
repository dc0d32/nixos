# pb-t480 — shared family laptop with parental-control accounts.
#
# Hardware: Lenovo ThinkPad T480 (8th-gen Coffee Lake, x86_64).
# Naming follows the pb-x1 scheme: "pb" (initials) + "t480" (model).
#
# Three NixOS users:
#   - p : admin (wheel), full HM mirror of pb-x1
#   - m : kid (no wheel), restricted GUI HM; full terminal dev/AI tooling
#   - s : kid (no wheel), restricted GUI HM; full terminal dev/AI tooling
#
# Kids' graphical session is the same niri / desktop-shell stack as p so
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
  central = config.flake.lib.timekprCentral;
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
  #   ./scripts/audio-discover.sh
  # which prints ready-to-paste autoload entries like:
  #   {
  #     device = "alsa_output.pci-0000_00_1f.3.analog-stereo";
  #     profile = "Speaker";
  #     description = "...";
  #     preset = "T480-Music";
  #   }
  # `profile` is the PipeWire *route description* ("Speaker",
  # "Headphones", …), NOT the ALSA card profile ("analog-stereo") —
  # EasyEffects keys its autoload rule filename on the former. Do not
  # hand-guess it; the script reads it out of pw-dump.
  #
  # Until an entry exists here every output — including the built-in
  # speakers — resolves to audio.fallbackPreset, i.e. the generated
  # "Passthrough" preset (no processing). Once the speaker rule is
  # added, the T480 behaves like pb-x1: preset on the built-in
  # speakers, stock audio path on bluetooth / HDMI / dock.
  audioCfg = {
    presetsDir = ../../hosts/pb-t480/audio-presets;
    # No IRS files — the presets don't reference convolver#0.
    # irsDir = ../../hosts/pb-t480/audio-irs;  # if/when measured
    autoloads = [ ];
  };

  # Shared per-host display layout — same for p, m, and s so every
  # account behaves identically when the laptop is docked. The T480's
  # built-in panel is 1920x1080 at 14"; pin scale 1 rather than letting
  # niri guess from DPI. External monitors are deliberately NOT listed:
  # whoever docks can arrange them with wdisplays (Mod+D) and persist
  # with `display-save` (Mod+Shift+D) — no rebuild and no wheel needed,
  # which matters because m and s are non-admin. Promote a good layout
  # into this attrset later with `display-export`.
  displaysCfg = {
    "eDP-1".scale = 1;
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
in
{
  # ── Top-level option values supplied by this host ────────────────
  # git identity, locale/timezone and wallpaper interval use their module
  # defaults now (git.nix, locale.nix, wallpaper.nix). Nothing to set.
  #
  # NOTE: `gpu.driver` + `battery.*` are set inside
  # `configurations.nixos.${hostName}.module`, and `audio.*` / `idle.*`
  # inside each HM module block below (per-(NixOS|HM)-config scoping; the
  # shared `audioCfg` lives in the `let` block above).

  # NOTE: `chrome-managed.*`, `timekpr.*` and `timekpr-sync.*` are also
  # set inside `configurations.nixos.${hostName}.module`, for the same
  # per-config scoping reason.

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

        # Disko: declarative disk layout. Provides config.fileSystems.*
        # (root/nix/home/.snapshots subvols, /boot ESP) plus a 32G
        # swap partition from the shared bare-metal layout factory.
        # /dev/nvme0n1 — single onboard NVMe on this T480.
        config.flake.modules.nixos.disko
        (config.flake.lib.diskoLayouts.bare-metal {
          disk = "/dev/nvme0n1";
          # 32 GiB swap partition — T480 ships with 32 GiB RAM, this
          # clears the hibernate requirement (swap >= RAM) with a
          # small margin. See flake-modules/disko.nix for why swap is
          # its own partition rather than a btrfs swapfile.
          swapSize = "32G";
        })

        # Hardware-specific defaults from nixos-hardware (kernel
        # modules, firmware, T480 quirks). Pulls in things like
        # thinkpad_acpi, microcode, sane TLP-vs-PPD defaults, etc.
        inputs.nixos-hardware.nixosModules.lenovo-thinkpad-t480
      ]
      # Bare-metal graphical core (impermanence + backup + gpu + power +
      # networking + nix-settings + system-utils + users + fonts + locale
      # + battery + audio + bluetooth + boot + file-manager + login-ly +
      # niri + lockscreen + home-manager-bootstrap). See
      # flake-modules/bundles/nixos-workstation.nix.
      ++ config.flake.lib.bundles.nixos.workstation
      # Daily auto-pull from origin/main (deployed-and-left family
      # laptop). See flake-modules/bundles/nixos-auto-deploy.nix.
      ++ config.flake.lib.bundles.nixos.auto-deploy
      ++ [
        # ── pb-t480-specific extras ─────────────────────────────────
        # Battery-aware power-profile auto-switching (laptop-only; not in
        # the workstation bundle since m-pc is a desktop). Enables PPD and
        # drives its profile from the battery%/AC matrix. See
        # flake-modules/power-profile-auto.nix.
        config.flake.modules.nixos.power-profile-auto
        # hardware-hacking (NixOS half) — udev rules + dialout/plugdev/
        # uucp membership for users.primary AND hardware-hacking.extraUsers
        # (set below to grant the kids device access for robotics work).
        config.flake.modules.nixos.hardware-hacking
        # Fingerprint (Synaptics) + PAM stack reordering.
        config.flake.modules.nixos.biometrics
        # Screen-time enforcement + Family-Link-locking Chrome policy.
        config.flake.modules.nixos.timekpr
        # Cross-host shared-budget agent — reports usage to the central
        # control plane and applies the shared remaining. See
        # flake-modules/timekpr-sync.nix.
        config.flake.modules.nixos.timekpr-sync
        config.flake.modules.nixos.chrome-managed
        # ── Docking ─────────────────────────────────────────────────
        # DisplayLink dock support (evdi + DisplayLinkManager). s docks
        # this laptop with a Lenovo ThinkPad Hybrid USB-C with USB-A
        # Dock (17e9:6015), which sends video over USB rather than DP
        # alt-mode. Without this its USB hub, ethernet and audio all
        # come up while the external monitors stay dark — which is
        # exactly the half-working dock experience s reported. See
        # flake-modules/displaylink.nix.
        config.flake.modules.nixos.displaylink
        # Thunderbolt authorization, for when this host is used with a
        # TB3/TB4 dock instead. See flake-modules/thunderbolt.nix.
        config.flake.modules.nixos.thunderbolt
        # (The steam module was deleted from the flake 2026-06-25.)
      ];

      networking.hostName = hostName;
      users.primary = primaryUser;

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
      timekpr.users = lib.genAttrs kidUsers (_: config.flake.lib.kidTimekprPolicy);

      # p is excluded from timekpr entirely — not merely absent from
      # `timekpr.users`. Without this the daemon enrolls p on first login
      # and auto-writes an unrestricted timekpr.p.conf: not limited, but
      # tracked, and one timekpra mis-click from locking the admin out of
      # this machine. p remains in the `timekpr` group below so they can
      # still drive timekpra/timekprc to grant ad-hoc time.
      timekpr.excludeUsers = [ primaryUser ];

      # Shared cross-host daily budget. This host reports the seconds m
      # and s each burn HERE to the controller on ursa and pulls back the
      # pool-wide remainder, so the budget rendered by `timekpr.users`
      # above is spent once per day across the whole fleet rather than
      # once per machine. See flake-modules/timekpr-sync.nix.
      #
      # Public hostname, not the LAN IP. AdGuard rewrites *.bitset.cc to
      # the DMZ edge for on-LAN clients, so this resolves from any VLAN
      # and rides a real wildcard cert — which is what stops a kid on the
      # LAN from ARP-spoofing the controller and forging themselves the
      # extra hour that `maxExtraMinutes` allows. Off the home LAN the
      # edge's LAN guard 403s, the agent no-ops, and the local cap stands.
      timekpr-sync = {
        serverUrl = central.url;
        users = kidUsers;
        token = central.reportToken;
      };

      # GPU driver is a guess — revisit after generating real hardware
      # config. T480 SKUs ship with Intel UHD 620 alone, or Intel +
      # Nvidia MX150 Optimus. flake-modules/gpu.nix only knows
      # intel/amd/nvidia/none — proper PRIME/Optimus support is a
      # follow-up commit once the real bus IDs are known from
      # `lspci -nn | grep -E 'VGA|3D'`.
      gpu.driver = "intel";

      # Grant the kid accounts USB-device access (dialout/plugdev/uucp)      # for robotics work — RP2040 UF2 flashing, ESP32 esptool runs,
      # picocom over USB-serial, etc. See flake-modules/hardware-
      # hacking.nix for why this is a NixOS-class option (per-host)
      # rather than a flake-parts top-level option (would leak to pb-x1
      # and try to add phantom m/s users there).
      hardware-hacking.extraUsers = kidUsers;

      # Let any physically-present user authorize a Thunderbolt dock
      # without an admin password. Unlike pb-x1, the T480's Alpine Ridge
      # controller predates firmware IOMMU DMA protection, so boltd
      # cannot silently auto-authorize and instead falls back to an
      # `auth_admin` polkit prompt. m and s are deliberately non-wheel,
      # so that prompt is unanswerable for them — a dock would be
      # permanently unusable on the accounts that use this laptop most.
      #
      # See the option description in flake-modules/thunderbolt.nix for
      # the DMA trade-off this accepts. Revisit if this host is ever
      # replaced by hardware with Kernel DMA Protection, where the
      # correct value is `false` (boltd then needs no help).
      thunderbolt.trustLocalUsers = true;

      # Battery / hibernate config (declared as a NixOS module option
      # by flake-modules/battery.nix). T480 has BAT0 (external
      # swappable, primary) and BAT1 (internal). Both get the same
      # charge thresholds — capping BAT1 at 80% costs nothing and
      # extends its lifespan alongside BAT0.
      #
      # Swap is provisioned by the disko factory above (swapSize =
      # "32G") as its own GPT partition; disko sets boot.resumeDevice
      # to the swap partition automatically, so hibernate-resume works
      # without any per-host resume_offset.
      battery = {
        batteries = [ "BAT0" "BAT1" ];
        chargeStopThreshold = 80;
        chargeStartThreshold = 75;
        criticalPercent = 10;
        criticalAction = "Hibernate";
      };

      # Bootloader policy lives in flake-modules/boot.nix (imported
      # above as config.flake.modules.nixos.boot). Override individual
      # systemd-boot settings here with mkForce if the real hardware
      # turns out to be BIOS/legacy and needs grub instead.
      # kernelPackages = linuxPackages_latest comes from the workstation
      # bundle (flake-modules/kernel-latest.nix).

      # Accounts (mkUser adds networkmanager; admin adds wheel).
      # initialPassword "changeme" — change on first login; survives the
      # impermanence wipe via the /etc/shadow copy-sync.
      #   - p   : admin + timekpr (can grant ad-hoc time at runtime).
      #   - m,s : kid (no wheel). networkmanager lets them join wifi
      #           themselves — the laptop travels (school, friends').
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

      # Base CLI (git/vim/curl/wget) comes from system-utils.nix; only
      # the host-specific kid-activity wrapper is added here.
      environment.systemPackages = [ familyActivity ];

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
          imports = config.flake.lib.bundles.homeManager.desktop ++ [
            # hardware-hacking HM tools — pb-t480 has the NixOS udev
            # rules + USB-device groups (hardware-hacking NixOS module
            # imported above), so the tools are actually usable here.
            config.flake.modules.homeManager.hardware-hacking
            # FreeCAD and Firefox are opt-in per-host because they are fat
            # downloads that not every desktop host wants.
            config.flake.modules.homeManager.freecad
            config.flake.modules.homeManager.firefox
          ];

          programs.home-manager.enable = true;

          # idle timings + EDITOR/VISUAL are module defaults now
          # (idle.nix 300/420/900, vim.nix "vim").

          # EasyEffects per-host data — shared with kids on this host.
          audio = audioCfg;

          # Display layout — shared with kids on this host.
          displays.outputs = displaysCfg;

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
          module = config.flake.lib.mkKidHmModule {
            username = kid;
            audio = audioCfg;
            displays = displaysCfg;
            extraImports = [ config.flake.modules.homeManager.freecad ];
          };
        };
      })
      kidUsers);
}
