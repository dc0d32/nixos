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
#   EasyEffects 8.x has no global "process all outputs" toggle. Per-sink
#   selection is done entirely via autoload rules in
#   ~/.config/easyeffects/autoload/output/. A rule
#   "<device>:<profile>.json" tells EE: "when this PipeWire sink
#   appears, load this preset on it." Sinks with no rule are left
#   flat/passthrough. We therefore deliberately do NOT write a global
#   `lastLoadedOutputPreset` into easyeffectsrc — that key would make
#   the configured preset apply to whatever sink happens to be default
#   on startup (e.g. bluetooth headphones), defeating per-sink scope.
#
# Pattern A: hosts opt in by importing this module on either class.
# WSL / headless / desktops without speakers simply don't import the
# HM side.
#
# Top-level options absorb the per-host data — the on-disk preset
# directory, the IRS directory, and a list of autoload rules
# (one entry per sink → preset binding). The preset and IRS dirs are
# paths into the host's own directory (e.g. hosts/pb-x1/audio-presets/)
# so they ship with the host they describe.
#
# Retire when: you switch off EasyEffects entirely (e.g. moving DSP
# into native PipeWire filter graphs), or upstream EasyEffects starts
# shipping its own systemd unit and we can drop the inline one.
{ lib, config, ... }:
let
  cfg = config.audio;

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
        description = "ALSA card profile (used in the autoload rule filename).";
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
        PipeWire sink (by node-name) to a single preset; sinks with
        no entry are left flat/passthrough. There is intentionally no
        global default — see the per-sink scoping note in the file
        header.
      '';
    };
  };

  # ── NixOS side ────────────────────────────────────────────────────
  config.flake.modules.nixos.audio = { lib, ... }: {
    security.rtkit.enable = true;
    services.pulseaudio.enable = false;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
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
  config.flake.modules.homeManager.audio = { pkgs, lib, ... }: {
    home.packages = [
      pkgs.easyeffects
      pkgs.calf
      pkgs.libebur128
      pkgs.rnnoise
      pkgs.deepfilternet
      pkgs.speexdsp
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

    # EasyEffects (newer versions) stores presets and IRS under
    # ~/.local/share/easyeffects/. Deploying to ~/.config/easyeffects/
    # output/ triggers a migration that fails on nix store read-only
    # symlinks, so everything goes to xdg.dataFile instead.
    xdg.dataFile = lib.mkMerge [
      (lib.optionalAttrs (cfg.irsDir != null)
        (lib.mapAttrs'
          (name: _:
            lib.nameValuePair "easyeffects/irs/${name}" {
              source = "${cfg.irsDir}/${name}";
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
    ];

    # Per-sink autoload rules. Filename format is
    # "<device>:<profile>.json" — exactly what EasyEffects writes when
    # you set up an autoload via the UI. One rule per sink keeps each
    # sink's preset isolated from the others; sinks without a rule
    # stay flat.
    xdg.configFile = lib.listToAttrs (map
      (rule: lib.nameValuePair
        "easyeffects/autoload/output/${rule.device}:${rule.profile}.json"
        {
          force = true;
          text = builtins.toJSON {
            device = rule.device;
            device-description = rule.description;
            device-profile = rule.profile;
            preset-name = rule.preset;
          };
        })
      cfg.autoloads);
  };
}
