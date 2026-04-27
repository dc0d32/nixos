{ pkgs, lib, variables, ... }:
let
  cfg = variables.audio.easyeffects or { enable = false; };
  preset = cfg.preset or null;
  presetsDir = cfg.presetsDir or null;
  irsDir = cfg.irsDir or null;
in
lib.mkIf cfg.enable {
  home.packages =
    [ pkgs.easyeffects pkgs.calf pkgs.libebur128 pkgs.rnnoise pkgs.deepfilternet pkgs.speexdsp ];

  # Deploy IRS impulse response files to the EasyEffects data dir.
  # Presets reference these by filename; EasyEffects looks in ~/.local/share/easyeffects/irs/.
  xdg.dataFile = lib.optionalAttrs (irsDir != null)
    (lib.mapAttrs' (name: _:
      lib.nameValuePair "easyeffects/irs/${name}" {
        source = "${irsDir}/${name}";
      }
    ) (builtins.readDir irsDir));

  # Deploy preset JSON files supplied by the host.
  # Each .json file becomes ~/.config/easyeffects/output/<name>.json
  xdg.configFile = lib.mkMerge [
    (lib.optionalAttrs (presetsDir != null)
      (lib.mapAttrs' (name: _:
        lib.nameValuePair "easyeffects/output/${name}" {
          source = "${presetsDir}/${name}";
        }
      ) (builtins.readDir presetsDir)))

    # Write EasyEffects' GSettings-backed INI db so it auto-loads the preset on
    # startup. The key EasyEffects reads is lastLoadedOutputPreset under [Presets].
    # (The "last-used-output-preset" text file is NOT read by EasyEffects.)
    (lib.optionalAttrs (preset != null) {
      "easyeffects/db/easyeffectsrc" = {
        force = true;
        text = ''
          [Presets]
          lastLoadedOutputPreset=${preset}
        '';
      };
    })
  ];
}
