# Audio — PipeWire (NixOS) and EasyEffects user-side preset wiring
# (home-manager).
#
# Cross-class footprint:
#   - flake.modules.nixos.audio — PipeWire + ALSA + Pulse + RTKit, with
#     a WirePlumber rule that caps output volume at 100% to prevent
#     digital clipping via the volume slider/keybinds.
#   - flake.modules.homeManager.audio — EasyEffects + plugin libs,
#     deploys per-host preset JSON, IRS impulse responses, an autoload
#     rule that applies the chosen preset when the configured sink
#     appears, and a user systemd service that runs EasyEffects with
#     --hide-window so the audio DSP keeps running across window-close,
#     suspend/resume, and Wayland reconnect events. Open the GUI on
#     demand by running `easyeffects` (no flags); closing the window
#     leaves the daemon alive because it's the GApplication primary,
#     and the launched UI is just a remote that exits when dismissed.
#
# Pattern A: hosts opt in by importing this module on either class.
# WSL / headless / desktops without speakers simply don't import the
# HM side.
#
# Top-level options absorb the per-host data — preset name, the on-disk
# preset directory, the IRS directory, and the autoload-target sink.
# The preset and IRS dirs are paths into the host's own directory (e.g.
# hosts/pb-x1/audio-presets/) so they ship with the host they
# describe.
#
# Retire when: you switch off EasyEffects entirely (e.g. moving DSP
# into native PipeWire filter graphs), or upstream EasyEffects starts
# shipping its own systemd unit and we can drop the inline one.
{ lib, config, ... }:
let
  cfg = config.audio;
in
{
  options.audio = {
    preset = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "X1Yoga7-Dynamic-Detailed";
      description = ''
        EasyEffects preset name (without .json) to load on startup
        and to wire into the autoload rule. Null disables both
        startup-load and autoload, leaving EasyEffects in
        flat/no-preset state.
      '';
    };
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
    autoloadDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink";
      description = ''
        PipeWire sink node-name to autoload the preset on. Get with:
        wpctl inspect @DEFAULT_AUDIO_SINK@ | grep node.name
      '';
    };
    autoloadDeviceProfile = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "Speaker";
      description = "ALSA card profile (used in the autoload rule filename).";
    };
    autoloadDeviceDescription = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Human-readable device description embedded in the autoload rule.";
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

      # Autoload rule: filename format is "<device>:<profile>.json" —
      # exactly what EasyEffects writes when you set it up via the
      # UI.
      (lib.optionalAttrs (cfg.autoloadDevice != null && cfg.preset != null) {
        "easyeffects/autoload/output/${cfg.autoloadDevice}:${cfg.autoloadDeviceProfile}.json" = {
          force = true;
          text = builtins.toJSON {
            device = cfg.autoloadDevice;
            device-description = cfg.autoloadDeviceDescription;
            device-profile = cfg.autoloadDeviceProfile;
            preset-name = cfg.preset;
          };
        };
      })
    ];

    # Write EasyEffects' GSettings-backed INI so the correct preset
    # is shown on startup.
    xdg.configFile = lib.optionalAttrs (cfg.preset != null) {
      "easyeffects/db/easyeffectsrc" = {
        force = true;
        text = ''
          [Presets]
          lastLoadedOutputPreset=${cfg.preset}
        '';
      };
    };
  };
}
