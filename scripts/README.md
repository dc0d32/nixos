# Speaker measurement tools

Maintenance tooling for the EasyEffects presets in
`hosts/<host>/audio-presets/`. **Not installed on any host** — these live
in this repo's devShell only:

```sh
nix develop                       # both tools on PATH
nix run .#preset-headroom -- hosts/pb-x1/audio-presets/*.json
nix run .#speaker-measure -- --self-test
```

Packaging is in `flake-modules/audio-tools.nix`.

| file | what |
| --- | --- |
| `audio_ess.py` | exponential-sine-sweep engine (library + self-test) |
| `speaker-measure.py` | acoustic response, cancelling the DSP loopback |
| `preset-headroom.py` | offline gain-staging check, no audio needed |
| `audio-discover.sh` | print an `audio.autoloads` entry for the current devices |

## Start here: `preset-headroom`

Pure offline. Models a preset's linear chain (convolver IR + LSP EQs +
fixed gains) against pink noise and reports how close it runs to
`limiter#0` and to each `multiband_compressor#1` band threshold.

```sh
preset-headroom hosts/pb-x1/audio-presets/*.json
preset-headroom hosts/pb-x1/audio-presets/X1Yoga7-Bass.json --gain 3
```

Non-zero exit if anything is `TIGHT` or `OVER`, so it works in a check.
`--gain` answers "would another N dB still be safe?" without editing
anything. Several candidate presets during the pb-x1 work sat *at* the
limiter — inaudible as clipping, but it squashes dynamics, and it is
trivially predictable on paper. Run this before auditioning anything.

It cannot model nonlinear stages (`bass_enhancer`, `exciter`, …); it says
so, and the real peak will be higher than reported.

## `speaker-measure`, and why it is not trivial

**The internal microphone may not be measuring your speakers.** On the
X1 Yoga Gen 7 (SOF + DMIC) the mic stream carries a DSP **echo
reference** — a digital copy of the playback. Mute the speakers at the
codec and a sweep *still records at full level*. Symptoms of falling for
this: a suspiciously flat response, and results that do not change when
you change the speaker volume.

The tool measures with the speakers muted and unmuted and
complex-subtracts, since both paths are linear and share one sweep:

```
H_acoustic = H_(speakers on) - H_(speakers off)
```

On the reference machine the loopback cancelled 39–40 dB, leaving the
acoustic signal ~33 dB above the cancellation floor. If your machine has
no loopback, the "off" capture is silence and the subtraction is a no-op.

Three things that will otherwise waste an afternoon:

- **Volume high, digital level low.** The loopback scales with the
  digital level; the acoustic scales with speaker volume. At volume 1.0 /
  −24 dBFS the acoustic ran 10 dB above the loopback; at volume 0.30 it
  was undetectable.
- **Play direct to the hardware sink.** Routing through `easyeffects_sink`
  adds run-to-run latency jitter that de-aligns the loopback and wrecks
  the cancellation (6 dB repeatability vs ~1 dB).
- **`Master Playback Switch` may not mute the speakers.** On the reference
  codec only `Speaker Playback Switch` + `Bass Speaker Playback Switch`
  did. The tool finds them by name and warns if neither exists.

Check the reported IQR. Above ~2 dB something is moving — fans, typing,
or a DSP sink in the path.

### Reading the result honestly

The mic is uncalibrated and near-field, so this is *speaker × mic*. Use it
for A/B comparisons (the mic response cancels), for narrow high-Q features
(those are the speaker; mic response is smooth), and for repeatability-
checked relative changes.

**Do not flatten the measured curve** — you would bake the microphone's
own response into your speakers. Results below ~200 Hz are additionally
gate-limited: the impulse response is windowed at −2/+150 ms to keep room
reverb out (4.21 dB rep-to-rep spread ungated vs 0.17 dB gated), and that
window cannot resolve long low-frequency ringing.

Distortion measurement was attempted on the reference machine and did not
work: the mic's dynamic range, already consumed by the loopback, left the
measurement noise-limited below −27 dBFS and mic-clipping-limited above
−21 dBFS. Two plausible-looking THD curves were produced before that was
noticed. Use an external mic if you need real THD.

## If you change the engine

`audio_ess.py` has a self-test with a known analytic answer:

```sh
nix run .#speaker-measure -- --self-test    # must print SELF TEST: PASS
```

It caught a real bug during development — the inverse-filter envelope sign
was inverted, producing a clean −12 dB/oct tilt that looked plausible.
Re-run it after touching the sweep, inverse filter or gating.
