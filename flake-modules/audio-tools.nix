# Speaker measurement / preset gain-staging tools.
#
# Why this exists: tuning the X1 Yoga's EasyEffects presets by ear
# (2026-08-14) needed a measurement rig, and rebuilding that rig from
# scratch for the next laptop would be an afternoon of rediscovering the
# same traps. The two non-obvious ones are documented at length in the
# scripts themselves:
#
#   - the internal mic on this SOF/DMIC machine carries a DSP echo
#     reference (a digital copy of the playback), so a naive sweep
#     measures the loopback rather than the speaker;
#   - the linear impulse response has to be time-gated tightly, or room
#     reverb and noise swamp the direct sound (4.21 dB rep-to-rep spread
#     vs 0.17 dB gated).
#
# DELIBERATELY NOT INSTALLED ANYWHERE. These are not in any host's
# systemPackages and not in home-manager. They exist only in this repo's
# devShell, because they are maintenance tooling for the presets in
# hosts/<host>/audio-presets/, not something any user needs on PATH.
#
# Exposed as flake packages so they can also be run ad hoc without
# entering the shell:
#   nix run .#preset-headroom -- hosts/pb-x1/audio-presets/*.json
#   nix run .#speaker-measure -- --self-test
#
# Retire when: the presets stop being hand-tuned, or upstream EasyEffects
# grows its own measurement/auto-EQ workflow.
{ ... }:
{
  perSystem = { pkgs, ... }:
    let
      py = pkgs.python3.withPackages (ps: [ ps.numpy ]);

      # `src` carries the shared audio_ess.py alongside each entry point so
      # the `sys.path` insert in the scripts resolves it.
      mkTool = { name, script, runtimeInputs ? [ ] }:
        pkgs.stdenvNoCC.mkDerivation {
          inherit name;
          src = pkgs.lib.fileset.toSource {
            root = ../scripts;
            fileset = pkgs.lib.fileset.unions [
              ../scripts/audio_ess.py
              script
            ];
          };
          nativeBuildInputs = [ pkgs.makeWrapper ];
          dontBuild = true;
          installPhase = ''
            mkdir -p $out/libexec $out/bin
            cp *.py $out/libexec/
            makeWrapper ${py}/bin/python3 $out/bin/${name} \
              --add-flags $out/libexec/${baseNameOf script} \
              ${pkgs.lib.optionalString (runtimeInputs != [ ])
                "--prefix PATH : ${pkgs.lib.makeBinPath runtimeInputs}"}
          '';
        };
    in
    {
      packages.preset-headroom = mkTool {
        name = "preset-headroom";
        script = ../scripts/preset-headroom.py;
      };

      # pw-* and wpctl come from pipewire/wireplumber, amixer from
      # alsa-utils. A machine being measured has all three already, but
      # pinning them keeps the tool working inside a bare `nix run`.
      packages.speaker-measure = mkTool {
        name = "speaker-measure";
        script = ../scripts/speaker-measure.py;
        runtimeInputs = with pkgs; [ pipewire wireplumber alsa-utils coreutils ];
      };
    };
}
