# Audio — PipeWire (NixOS) and EasyEffects user-side preset wiring
# (home-manager).
#
# Cross-class footprint:
#   - flake.modules.nixos.audio — PipeWire + ALSA + Pulse + RTKit, with
#     a WirePlumber rule that caps output volume at 100% to prevent
#     digital clipping via the volume slider/keybinds.
#   - flake.modules.homeManager.audio — EasyEffects + plugin libs,
#     deploys per-host preset JSON, IRS impulse responses, and a list
#     of per-sink autoload rules so that each sink (built-in speakers,
#     bluetooth headphones, …) gets exactly the preset configured for
#     it — and nothing else. A user systemd service runs EasyEffects
#     with --hide-window so the audio DSP keeps running across
#     window-close, suspend/resume, and Wayland reconnect events. Open
#     the GUI on demand by running `easyeffects` (no flags); closing
#     the window leaves the daemon alive because it's the GApplication
#     primary, and the launched UI is just a remote that exits when
#     dismissed.
#
# Per-sink scoping:
#   EasyEffects 8.x has no global "process all outputs" toggle, and it
#   runs exactly ONE output pipeline bound to whatever sink is current
#   (`DbStreamOutputs::outputDevice`). Per-sink selection is therefore
#   done entirely via autoload rules in
#   ~/.local/share/easyeffects/autoload/output/. A rule
#   "<device>:<route-description>.json" tells EE: "when this PipeWire
#   sink becomes current, load this preset." We deliberately do NOT
#   write a global `lastLoadedOutputPreset` into easyeffectsrc — that
#   key would make the configured preset apply to whatever sink happens
#   to be default on startup (e.g. bluetooth headphones), defeating
#   per-sink scope.
#
#   TWO non-obvious upstream behaviours drive the shape of this module:
#
#   1. Autoload rules live under XDG_DATA_HOME, not XDG_CONFIG_HOME.
#      presets_directory_manager.cpp builds autoload_output_dir as
#      `AppDataLocation / "autoload/output"`. EE ships an
#      `xdg_migration()` that copies a legacy ~/.config/easyeffects/
#      autoload/ tree into the data dir — but `copy_file` inherits the
#      source's mode, and a nix-store source is 0444, so the *second*
#      migration fails with EPERM and aborts. Deploying to
#      xdg.configFile therefore froze the rule at whatever it happened
#      to be on the first successful run. Everything goes to
#      xdg.dataFile now; the activation script below sweeps up the
#      0444 leftovers and the stale config-side tree.
#
#   2. When no rule matches, `AutoloadManager::load()` returns WITHOUT
#      touching the pipeline unless the fallback is enabled — so the
#      previously-loaded preset (built-in speaker EQ + speaker
#      convolver IR) stayed applied to bluetooth headphones, HDMI and
#      dock sinks. The fix is EE's own fallback mechanism: we ship a
#      neutral `Passthrough` preset (empty plugins_order) and point
#      `output/inputAutoloadingFallbackPreset` at it. Any device
#      without an explicit rule now gets an EMPTY effects chain, i.e.
#      the untouched default audio path.
#
# Pattern A: hosts opt in by importing this module on either class.
# WSL / headless / desktops without speakers simply don't import the
# HM side.
#
# Per-host data (preset directory, IRS directory, autoload rules) is
# declared as **HM module options** (NOT flake-parts singletons) so
# multi-laptop hosts can each carry their own values without
# conflicts. Each HM config sets `audio = { … };` inside its own
# `configurations.homeManager.<id>.module` block. Same fix as
# battery.nix and idle.nix.
#
# Retire when: you switch off EasyEffects entirely (e.g. moving DSP
# into native PipeWire filter graphs), or upstream EasyEffects starts
# shipping its own systemd unit and we can drop the inline one.
{ lib, ... }:
let
  # Name of the neutral preset this module generates and points EE's
  # autoload fallback at. Empty plugins_order → EE tears the effects
  # chain down to nothing, i.e. the stock audio path.
  passthroughPresetName = "Passthrough";

  mkPassthroughPreset = pipeline: builtins.toJSON {
    ${pipeline} = {
      blocklist = [ ];
      plugins_order = [ ];
    };
  };

  # Byte-for-byte the shape AutoloadManager::add() writes from the GUI.
  mkAutoloadRule = rule: builtins.toJSON {
    device = rule.device;
    device-description = rule.description;
    device-profile = rule.profile;
    preset-name = rule.preset;
  };

  autoloadType = lib.types.submodule {
    options = {
      device = lib.mkOption {
        type = lib.types.str;
        example = "alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink";
        description = ''
          PipeWire sink node-name to autoload the preset on. Get with:
          wpctl inspect @DEFAULT_AUDIO_SINK@ | grep node.name
        '';
      };
      profile = lib.mkOption {
        type = lib.types.str;
        example = "Speaker";
        description = ''
          PipeWire *route description* for the device (what EE calls the
          "device profile" in the autoload rule filename). This is the
          `description` of the device's active Route param, NOT the ALSA
          card profile name — e.g. "Speaker", "Headphones", "Digital
          Microphone". Get it with `./scripts/audio-discover.sh`.
        '';
      };
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Human-readable device description embedded in the autoload rule.";
      };
      preset = lib.mkOption {
        type = lib.types.str;
        example = "X1Yoga7-Dynamic-Detailed";
        description = ''
          EasyEffects preset name (without .json) to apply when this
          sink appears. Must match a file in `presetsDir`.
        '';
      };
    };
  };
in
{
  # ── NixOS side ────────────────────────────────────────────────────
  flake.modules.nixos.audio = { lib, ... }: {
    security.rtkit.enable = true;
    services.pulseaudio.enable = false;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      # No alsa.support32Bit: the only consumer of 32-bit audio was
      # Steam, which has been removed from this flake. If Steam ever
      # comes back, nixpkgs' programs.steam auto-sets
      # services.pipewire.alsa.support32Bit (and
      # hardware.graphics.enable32Bit) itself, so don't re-add it by
      # hand. Dropping it also avoids building the whole i686 pipewire
      # stack (ffado → scons → a python env with pandas/pybind11,
      # libcamera → pybind11) from source, since cache.nixos.org doesn't
      # populate the i686 variant.
      pulse.enable = true;
      jack.enable = lib.mkDefault false;
      wireplumber.extraConfig."99-volume-limit" = {
        "monitor.alsa.rules" = [{
          matches = [{ "node.name" = "~alsa_output.*"; }];
          actions.update-props = {
            # Cap output volume at 100% (1.0) to prevent digital
            # clipping via the volume slider/keybinds. Raise (e.g.
            # 1.5 for 150%) only if you trust your downstream gain
            # staging.
            "channelmix.max-volume" = 1.0;
          };
        }];
      };
    };
  };

  # ── home-manager side ────────────────────────────────────────────
  flake.modules.homeManager.audio = { pkgs, lib, config, ... }:
    let
      cfg = config.audio;
    in
    {
      options.audio = {
        presetsDir = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "./audio-presets";
          description = ''
            Directory of EasyEffects output preset JSON files to deploy
            under ~/.local/share/easyeffects/output/. Each top-level file
            becomes a symlink into the nix store.
          '';
        };
        irsDir = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "./audio-irs";
          description = ''
            Directory of IRS impulse-response files to deploy under
            ~/.local/share/easyeffects/irs/. Required if any preset
            references the convolver stage by kernel-name.
          '';
        };
        autoloads = lib.mkOption {
          type = lib.types.listOf autoloadType;
          default = [ ];
          example = lib.literalExpression ''
            [
              {
                device = "alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink";
                profile = "Speaker";
                description = "Alder Lake PCH-P High Definition Audio Controller Speaker";
                preset = "X1Yoga7-Dynamic-Detailed";
              }
              {
                device = "bluez_output.AA_BB_CC_DD_EE_FF.1";
                profile = "headset-head-unit";
                description = "Sony WH-1000XM4";
                preset = "WH1000XM4-Flat";
              }
            ]
          '';
          description = ''
            List of per-sink autoload rules. Each entry binds a single
            PipeWire sink (by node-name) to a single preset. Sinks with
            no entry fall back to `fallbackPreset` (a flat passthrough
            chain by default), which is what keeps bluetooth headphones,
            HDMI and dock outputs on the untouched default audio path.
            There is intentionally no global "apply everywhere" default
            — see the per-sink scoping note in the file header.
          '';
        };

        inputPresetsDir = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "./audio-presets-input";
          description = ''
            Directory of EasyEffects *input* (microphone) preset JSON
            files to deploy under ~/.local/share/easyeffects/input/.
            Same deal as `presetsDir`, other pipeline.
          '';
        };

        inputAutoloads = lib.mkOption {
          type = lib.types.listOf autoloadType;
          default = [ ];
          example = lib.literalExpression ''
            [
              {
                device = "alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic1__source";
                profile = "Digital Microphone";
                description = "Alder Lake PCH-P High Definition Audio Controller Digital Microphone";
                preset = "X1Yoga7-Mic";
              }
            ]
          '';
          description = ''
            Per-source autoload rules for the input (microphone)
            pipeline. Same semantics as `autoloads`; sources with no
            entry get `inputFallbackPreset`.
          '';
        };

        fallbackPreset = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = passthroughPresetName;
          description = ''
            EasyEffects output preset autoloaded for any sink that has no
            entry in `autoloads`. Defaults to the module-generated
            "${passthroughPresetName}" preset — an empty effects chain, so
            bluetooth / HDMI / dock outputs stay on the stock audio path
            instead of inheriting the built-in speaker's correction.

            Set to null to disable the fallback entirely, which restores
            upstream EasyEffects behaviour: the last-loaded preset stays
            applied to whatever device you switch to.
          '';
        };

        inputFallbackPreset = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = passthroughPresetName;
          description = ''
            Input-pipeline twin of `fallbackPreset`. Applies to any
            source with no entry in `inputAutoloads`.
          '';
        };

        clearBypass = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Reset EasyEffects' global Bypass switch to off on every
            home-manager activation. Scoping is handled by autoload rules
            now, so a sticky global bypass (the usual manual workaround
            for "my speaker preset followed me onto my headphones") would
            just disable the DSP everywhere. Set to false if you want the
            GUI toggle to survive activations.
          '';
        };
      };

      config = {
        home.packages = [
          pkgs.easyeffects
          pkgs.calf
          pkgs.libebur128
          pkgs.rnnoise
          pkgs.deepfilternet
          pkgs.speexdsp
          # PipeWire-native mixer + output-device picker. Conceptually
          # part of the audio stack: gives users (especially the kid
          # accounts on pb-t480, which can't sudo) a GUI to switch the
          # default output sink between built-in speakers, HDMI, USB
          # DACs, and connected bluetooth headphones, plus per-app
          # routing. Lives here (in the audio HM module) rather than
          # the desktop bundle because it makes no sense without
          # PipeWire on the system side.
          pkgs.pwvucontrol
        ];

        # Run EasyEffects as a supervised user service with a hidden
        # window. Background:
        #   - Easy Effects 8.x (Qt port) exits when its window closes; the
        #     audio processing dies with the GUI.
        #   - On suspend / niri restart / pipewire reconnect storm, the
        #     Wayland connection breaks ("The Wayland connection broke. Did
        #     the Wayland compositor die?") and the process exits cleanly.
        #     With no supervisor it just stays dead and your audio loses
        #     all DSP until you remember to relaunch.
        #   - --service-mode and --gapplication-service are *remote-control*
        #     flags: they connect to /run/user/$UID/EasyEffectsServer on an
        #     existing primary instance, send a "be in service mode"
        #     message, and exit. Used as the unit's ExecStart they exit in
        #     ~170 ms with status 0 and the unit goes inactive. So we don't
        #     use them.
        # Instead we run plain `easyeffects --hide-window`. The unit IS
        # the primary GApplication: it owns the unix socket, runs DSP, and
        # never shows a window. Subsequent invocations of `easyeffects`
        # (e.g. from the desktop entry) connect to this primary as remotes,
        # show the GUI, and exit on close without taking the daemon with
        # them.
        #
        # The wireplumber + pipewire user services live in
        # services.pipewire on the NixOS side; we only need to wait on
        # them here. graphical-session.target ensures we stop on logout.
        systemd.user.services.easyeffects = {
          Unit = {
            Description = "Easy Effects (audio DSP daemon)";
            After = [
              "pipewire.service"
              "wireplumber.service"
              "graphical-session.target"
            ];
            Wants = [
              "pipewire.service"
              "wireplumber.service"
            ];
            PartOf = [ "graphical-session.target" ];
            # Bound the restart loop: 10 attempts in 5 minutes, then give
            # up and let the user investigate. StartLimit* keys live in
            # [Unit], not [Service] — systemd warns and ignores them
            # otherwise.
            StartLimitBurst = 10;
            StartLimitIntervalSec = 300;
          };

          Service = {
            Type = "exec";
            ExecStart = "${pkgs.easyeffects}/bin/easyeffects --hide-window";
            # Restart on ANY exit, including clean (status 0) exits. The
            # Wayland-disconnect path on suspend/resume and the
            # `easyeffects --quit` remote-control flag both cause the
            # primary to exit cleanly; with Restart=on-failure the
            # supervisor would let DSP stay dead. The StartLimitBurst cap
            # in [Unit] bounds runaway loops if pipewire is genuinely
            # broken.
            Restart = "always";
            RestartSec = 3;
          };

          Install.WantedBy = [ "graphical-session.target" ];
        };

        # EasyEffects 8.x keeps presets, IRS *and* autoload rules under
        # XDG_DATA_HOME (QStandardPaths::AppDataLocation), i.e.
        # ~/.local/share/easyeffects/. Its xdg_migration() will happily
        # copy a legacy ~/.config/easyeffects/ tree over, but the copy
        # preserves the 0444 mode of a nix-store source and then fails
        # with EPERM forever after — so never deploy any of this via
        # xdg.configFile. `force = true` everywhere so the activation
        # takes over files left behind by that migration.
        xdg.dataFile = lib.mkMerge [
          (lib.optionalAttrs (cfg.irsDir != null)
            (lib.mapAttrs'
              (name: _:
                lib.nameValuePair "easyeffects/irs/${name}" {
                  source = "${cfg.irsDir}/${name}";
                  force = true;
                })
              (builtins.readDir cfg.irsDir)))

          (lib.optionalAttrs (cfg.presetsDir != null)
            (lib.mapAttrs'
              (name: _:
                lib.nameValuePair "easyeffects/output/${name}" {
                  source = "${cfg.presetsDir}/${name}";
                  force = true;
                })
              (builtins.readDir cfg.presetsDir)))

          (lib.optionalAttrs (cfg.inputPresetsDir != null)
            (lib.mapAttrs'
              (name: _:
                lib.nameValuePair "easyeffects/input/${name}" {
                  source = "${cfg.inputPresetsDir}/${name}";
                  force = true;
                })
              (builtins.readDir cfg.inputPresetsDir)))

          # The neutral fallback preset. Deployed whenever a fallback is
          # configured under the generated name; a host that points
          # `fallbackPreset` at one of its own presets gets nothing extra.
          (lib.optionalAttrs (cfg.fallbackPreset == passthroughPresetName) {
            "easyeffects/output/${passthroughPresetName}.json" = {
              force = true;
              text = mkPassthroughPreset "output";
            };
          })
          (lib.optionalAttrs (cfg.inputFallbackPreset == passthroughPresetName) {
            "easyeffects/input/${passthroughPresetName}.json" = {
              force = true;
              text = mkPassthroughPreset "input";
            };
          })

          # Per-device autoload rules. Filename format is
          # "<device>:<route-description>.json" — exactly what
          # EasyEffects writes when you add an autoload profile from the
          # Presets → Autoloading tab. One rule per device keeps each
          # device's preset isolated; devices without a rule get the
          # fallback preset instead of silently inheriting whatever was
          # loaded last.
          (lib.listToAttrs (map
            (rule: lib.nameValuePair
              "easyeffects/autoload/output/${rule.device}:${rule.profile}.json"
              {
                force = true;
                text = mkAutoloadRule rule;
              })
            cfg.autoloads))

          (lib.listToAttrs (map
            (rule: lib.nameValuePair
              "easyeffects/autoload/input/${rule.device}:${rule.profile}.json"
              {
                force = true;
                text = mkAutoloadRule rule;
              })
            cfg.inputAutoloads))
        ];

        # EasyEffects' own settings database. The autoload FALLBACK is
        # the piece that actually turns the DSP off on unlisted devices
        # (see header note 2), and it lives in easyeffectsrc rather than
        # in a file we can own outright: EasyEffects rewrites that file
        # itself (window geometry, most-used presets, current device …),
        # so a nix-store symlink would either be clobbered or block the
        # app's own writes. Seed just our keys with kwriteconfig6 and
        # leave the rest of the file alone.
        #
        # `kcfgfile name="easyeffects/db/easyeffectsrc"` is relative to
        # XDG_CONFIG_HOME, and the autoloading keys live in the [Window]
        # group (easyeffects_db.kcfg — the group spans the whole first
        # block, the name is historical).
        #
        # Ordering: entryBetween keeps this after linkGeneration (so the
        # Passthrough preset and the autoload rules are on disk before EE
        # is restarted into them) and before home-manager reloads
        # systemd.
        #
        # The stop-then-start dance is NOT optional. EasyEffects installs
        # a SIGTERM handler (main.cpp SignalHandler → QCoreApplication::
        # quit()), so a graceful shutdown runs db::Manager::~Manager() →
        # saveAll() → writes its whole in-memory settings tree back to
        # easyeffectsrc. Writing our keys while the daemon is alive and
        # then restarting it would therefore lose them on the way down.
        # Stop first, edit the file nobody is holding, start again.
        home.activation.easyeffectsDb =
          lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "linkGeneration" ] ''
            eeRc="${config.xdg.configHome}/easyeffects/db/easyeffectsrc"
            eeData="${config.xdg.dataHome}/easyeffects"

            # Sweep up the pre-2026-08 mistake: autoload rules used to be
            # deployed to ~/.config/easyeffects/autoload/, which EE then
            # copied into the data dir as 0444 regular files. Those
            # copies shadow the ones home-manager now manages (and cannot
            # be overwritten by EE's own migration, which is why the rule
            # froze at its first-ever value). Drop every unwritable plain
            # file — home-manager's own entries are symlinks and hand-made
            # GUI rules are 0644, so both survive. Then drop the legacy
            # config-side tree that keeps re-triggering the migration.
            for d in output input; do
              if [ -d "$eeData/autoload/$d" ]; then
                find "$eeData/autoload/$d" -maxdepth 1 -type f ! -writable \
                  -name '*.json' -exec $DRY_RUN_CMD rm -f {} +
              fi
            done
            if [ -d "${config.xdg.configHome}/easyeffects/autoload" ]; then
              $DRY_RUN_CMD rm -rf "${config.xdg.configHome}/easyeffects/autoload"
            fi

            # systemd is NOT on home-manager's activation PATH — reference
            # systemctl by store path the way home-manager's own
            # reloadSystemd entry does, or this silently no-ops with
            # "systemctl: command not found".
            systemctl=${lib.getExe' pkgs.systemd "systemctl"}

            eeWasRunning=0
            if [ -n "''${XDG_RUNTIME_DIR:-}" ] \
              && "$systemctl" --user is-active --quiet easyeffects.service; then
              eeWasRunning=1
              $DRY_RUN_CMD "$systemctl" --user stop easyeffects.service
            fi

            $DRY_RUN_CMD mkdir -p "$(dirname "$eeRc")"

            kw() {
              $DRY_RUN_CMD ${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} \
                --file "$eeRc" --group "$1" --key "$2" "$3"
            }

            kw Window outputAutoloadingUsesFallback ${lib.boolToString (cfg.fallbackPreset != null)}
            kw Window outputAutoloadingFallbackPreset ${lib.escapeShellArg (toString cfg.fallbackPreset)}
            kw Window inputAutoloadingUsesFallback ${lib.boolToString (cfg.inputFallbackPreset != null)}
            kw Window inputAutoloadingFallbackPreset ${lib.escapeShellArg (toString cfg.inputFallbackPreset)}
            ${lib.optionalString cfg.clearBypass ''
              kw EffectsPipelines bypass false
            ''}

            if [ "$eeWasRunning" = 1 ]; then
              $DRY_RUN_CMD "$systemctl" --user start easyeffects.service || true
            fi
          '';
      };
    };
}
