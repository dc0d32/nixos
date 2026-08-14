# Capture-gain override for internal digital microphones.
#
# Why: on the X1 Yoga Gen 7 (sof-hda-dsp) the UCM profile brings
# `Dmic0 Capture Volume` up at its maximum, 70/70 = +20 dB. That is enough
# gain that ORDINARY ROOM NOISE clips the capture — measured with a ceiling
# fan running, 0.96 % of samples pinned at full scale, 95 % of the energy
# below 200 Hz. Calls and recordings are distorted before anyone speaks.
#
# Measured in a quiet room with a deliberately loud acoustic source, peak
# capture level by setting:
#
#     70 (+20 dB)  peak 1.37, 0.10 % clipped   <- ships like this
#     65 (+15 dB)  peak 0.92
#     60 (+10 dB)  peak 1.29, 0.02 % clipped
#     55  (+5 dB)  peak 0.65, clean            <- what pb-x1 uses
#     50   (0 dB)  peak 0.83, clean
#
# 55 was clean across repeated runs where 60 was marginal, and the
# silent-room floor there sits around -54 dBFS, leaving a very large
# dynamic range for speech.
#
# This costs nothing in signal-to-noise ratio: the control is a DIGITAL
# gain inside the SOF DSP, after the ADC, so lowering it scales signal and
# noise together and only buys headroom. Anything wanting a hotter stream
# can raise the PipeWire source volume or use its own AGC (Zoom, Meet and
# Chrome all do).
#
# Why a systemd unit rather than saved ALSA state: this host runs no
# `alsa-store`/`alsa-restore`, so the control returns to the UCM default on
# every boot. The unit re-applies on resume too, since the codec is
# reinitialised across suspend.
#
# Card and control are addressed BY NAME. Card indices move when other
# sound devices (USB headsets, HDMI) appear, and control `numid`s are not
# stable across kernel or topology updates — the exploratory work behind
# this module used `numid=43`, which would have silently retargeted.
#
# Retire when: the UCM profile upstream stops defaulting this to maximum,
# or the host gains a general ALSA state save/restore that captures it.
{ lib, config, ... }:
{
  options.micGain = {
    card = lib.mkOption {
      type = lib.types.str;
      default = "sofhdadsp";
      example = "sofhdadsp";
      description = ''
        ALSA card NAME (the bracketed id in `/proc/asound/cards`), not its
        index. Passed to `amixer -c`.
      '';
    };

    controls = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = { };
      example = lib.literalExpression ''{ "Dmic0 Capture Volume" = 55; }'';
      description = ''
        ALSA control name to value. The value is applied to every channel
        of the control. Names, ranges and current values come from
        `amixer -c <card> controls` and `amixer -c <card> cget name='<n>'`.

        Empty by default, so importing this module on a host that declares
        nothing is a no-op — each host states what its own hardware needs.
      '';
    };
  };

  config.flake.modules.nixos.mic-gain =
    let
      cfg = config.micGain;
    in
    { pkgs, ... }:
    let
      apply = pkgs.writeShellApplication {
        name = "apply-mic-gain";
        runtimeInputs = [ pkgs.alsa-utils ];
        text = ''
          # Best effort: a control that has gone away must not fail the
          # boot, so each cset is tolerated individually and reported.
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList
            (name: value: ''
              if amixer -c ${lib.escapeShellArg cfg.card} \
                   cset name=${lib.escapeShellArg name} ${toString value} >/dev/null; then
                echo "set ${name} = ${toString value}"
              else
                echo "warning: could not set ${name} on card ${cfg.card}" >&2
              fi
            '')
            cfg.controls)}
        '';
      };
    in
    lib.mkIf (cfg.controls != { }) {
      systemd.services.mic-gain = {
        description = "Apply internal microphone capture gain";
        # sound.target is reached once the card's controls exist; without
        # the ordering the cset can land before the device node appears.
        after = [ "sound.target" ];
        wants = [ "sound.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe apply;
        };
      };

      # The codec is reinitialised across suspend, which restores the UCM
      # default. Same hook flake-modules/displaylink.nix uses.
      powerManagement.resumeCommands = ''
        ${lib.getExe apply} || true
      '';
    };
}
