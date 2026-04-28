{ pkgs, lib, variables, ... }:
let
  cfg = variables.audio.easyeffects or { enable = false; };
  preset = cfg.preset or null;
  presetsDir = cfg.presetsDir or null;
  irsDir = cfg.irsDir or null;
  autoloadDevice = cfg.autoloadDevice or null;
  autoloadDeviceProfile = cfg.autoloadDeviceProfile or "";
  autoloadDeviceDescription = cfg.autoloadDeviceDescription or "";
in
lib.mkIf cfg.enable {
  home.packages =
    [ pkgs.easyeffects pkgs.calf pkgs.libebur128 pkgs.rnnoise pkgs.deepfilternet pkgs.speexdsp ];

  # EasyEffects (newer versions) stores presets and IRS under ~/.local/share/easyeffects/.
  # Deploying to ~/.config/easyeffects/output/ triggers a migration that fails on nix store
  # read-only symlinks, so everything goes to xdg.dataFile instead.
  xdg.dataFile = lib.mkMerge [
    (lib.optionalAttrs (irsDir != null)
      (lib.mapAttrs' (name: _:
        lib.nameValuePair "easyeffects/irs/${name}" {
          source = "${irsDir}/${name}";
        }
      ) (builtins.readDir irsDir)))

    (lib.optionalAttrs (presetsDir != null)
      (lib.mapAttrs' (name: _:
        lib.nameValuePair "easyeffects/output/${name}" {
          source = "${presetsDir}/${name}";
          force = true;
        }
      ) (builtins.readDir presetsDir)))

    # Autoload rule: filename format is "<device>:<profile>.json" — exactly what
    # EasyEffects writes when you set it up via the UI.
    (lib.optionalAttrs (autoloadDevice != null && preset != null) {
      "easyeffects/autoload/output/${autoloadDevice}:${autoloadDeviceProfile}.json" = {
        force = true;
        text = builtins.toJSON {
          device = autoloadDevice;
          device-description = autoloadDeviceDescription;
          device-profile = autoloadDeviceProfile;
          preset-name = preset;
        };
      };
    })
  ];

  # Write EasyEffects' GSettings-backed INI so the correct preset is shown on startup.
  xdg.configFile = lib.optionalAttrs (preset != null) {
    "easyeffects/db/easyeffectsrc" = {
      force = true;
      text = ''
        [Presets]
        lastLoadedOutputPreset=${preset}
      '';
    };
  };
}
