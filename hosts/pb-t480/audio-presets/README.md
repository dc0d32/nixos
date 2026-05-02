# T480 EasyEffects presets

Hand-tuned for the Lenovo ThinkPad T480's stock audio: Realtek
ALC257 codec driving two 2W down-firing speakers in the palmrest.

Unlike `hosts/pb-x1/audio-presets/`, these are NOT extracted from a
Lenovo Windows driver — the T480 is not a Dolby Atmos / DAX3
licensed model, so there are no precomputed IR coefficients to
extract. These are hand-EQ'd corrections based on the well-known
ALC257 + tiny-driver weaknesses:

- Bass roll-off below ~250 Hz (drivers physically can't move enough
  air for low frequencies; high-pass at 100/150 Hz prevents wasted
  cone excursion + distortion).
- Boxiness around 350-500 Hz (palmrest cabinet resonance).
- Mid-range honk around 1.0-1.5 kHz (cone breakup mode).
- Sibilance around 7-8 kHz (cheap soft-dome tweeter resonance).
- Distortion at high SPL (limiter at -3 dBFS for music, -2 dBFS
  for voice, with conservative -2 / -1 dB output trim).

## Files

- `T480-Music.json` — 6-band parametric EQ + safety limiter. Bass
  warmth shelf, midrange honk dip, gentle presence + sibilance cut.
  Default for music / video / general use.
- `T480-Voice.json` — 5-band, narrower bandwidth. Aggressive
  high-pass at 150 Hz, presence boost at 1.8 + 3.5 kHz for speech
  intelligibility, sibilance dip at 7 kHz. Use for podcasts /
  meetings / lectures where dialog clarity beats musicality.

No convolver / IRS files are used — pure parametric EQ. If you
later capture a real impulse response of the T480 speakers (e.g.
with REW + a calibrated mic at typing position), drop the .irs
under `hosts/pb-t480/audio-irs/` and wire `audio.irsDir` in the
host bridge; the existing presets can be amended to add a
`convolver#0` stage referencing the new kernel-name.

## Activating

The host bridge `flake-modules/hosts/pb-t480.nix` references
`audio.presetsDir = ../../hosts/pb-t480/audio-presets;` so these
files land at `~/.local/share/easyeffects/output/` for every HM
account on pb-t480 (p, m, s).

`audio.autoloads` is intentionally empty until the actual T480
PipeWire sink node-name is captured on the live hardware (we can't
guess it from a different host). Run:

```
./scripts/host-setup.sh --audio-discover
```

on the T480 itself; it prints the autoload entry to paste into
`audio.autoloads = [ ... ]` in the host bridge.

Until then, EasyEffects runs in passthrough; users can apply
either preset by hand from the EE GUI (Presets tab → Output) to
audition them.
