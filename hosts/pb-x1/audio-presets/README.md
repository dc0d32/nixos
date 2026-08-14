# X1 Yoga Gen 7 EasyEffects presets

Extracted from the Lenovo Windows driver's Dolby DAX3 profiles — the X1
Yoga Gen 7 *is* a licensed Atmos model, so unlike
`hosts/pb-t480/audio-presets/` these are real vendor-measured
corrections rather than hand-EQ. Each `<name>.json` pairs with the
matching `<name>.irs` in `../audio-irs/`; the convolver stage references
its impulse response by `kernel-name`, so the two must be renamed
together.

Only one of these is actually applied automatically:
`X1Yoga7-Dynamic-Detailed`, bound to the built-in speaker by
`audio.autoloads` in `flake-modules/hosts/pb-x1.nix`. The rest are
selectable by hand from the EasyEffects GUI (or `easyeffects -l <name>`).

## Deliberate deviation from the vendor export

**These are no longer pristine exports.** If you ever re-extract them
from the Windows driver, re-apply this change or they will silently get
quieter again. Of the 27 presets here, 24 carried the padding:

- `equalizer#0.output-gain`: `-3.0` → `0.0`
- `autogain#0` removed from `plugins_order` (and its settings block
  dropped)

### Why

The chain gave away ~4.8 dB against bypass measured with pink noise,
while peaks still sat 4.4 dB below `limiter#0`'s -1 dBFS threshold — the
padding was not protecting anything. After the change there is still
+1.4 dB of peak headroom to the limiter and ≥8 dB of margin in every
`multiband_compressor#1` (excursion limiter) band.

`autogain#0` was present in the pipeline with `bypass: true`. A bypassed
EasyEffects plugin is still instantiated as a live PipeWire filter node
(`ee_soe_autogain`), so dropping it removes a node from the graph and
changes nothing audibly.

Supporting evidence that the padding is not load-bearing: the
`X1Yoga7-Voice-*` presets already ship from the vendor with
`equalizer#0.output-gain: -0.0` and no `autogain#0` in `plugins_order`.

The remaining three (`X1Yoga7-Voice-*`) already shipped at `-0.0`, but
all 27 carried an `autogain#0` settings block: 24 wired into
`plugins_order` (bypassed), and 3 as **orphans** — present in the file
but absent from `plugins_order`, so never instantiated at all. All 27
blocks were dropped; inert either way.

### How it was validated

Verified by ear on 2026-08-14: `X1Yoga7-Dynamic-Detailed` A/B'd against
the unmodified preset at high volume on the built-in speakers, listening
for breakup. Also compared against a variant with the `equalizer#1`
2.5 kHz presence bell removed — that variant was rejected, so the bell
stays.

The change was then propagated to the rest of the family on the strength
of modelling rather than listening: every preset was checked to still
clear `limiter#0` after +3 dB (worst case +0.56 dB, the
`Personalize_User*-Detailed` trio) and to keep ≥8 dB of margin in every
enabled `multiband_compressor#1` band. Zero presets came out risky. Only
`Dynamic-Detailed` has actually been heard, so if another preset ever
sounds strained at high volume, that gain is the first thing to suspect.

## What could not be established

An attempt to tune these by acoustic measurement failed — the built-in
microphone carries a DSP echo reference that swamps the acoustic signal,
and once cancelled, the remaining dynamic range was too small to measure
distortion. In particular the large 500–1250 Hz scoop in the vendor IR
is **unvalidated**: it is directionally plausible (the driver does appear
to be prominent around 630 Hz–1 kHz) but its depth could not be judged
with an uncalibrated near-field mic. Do not "correct" it without a
proper measurement microphone.
