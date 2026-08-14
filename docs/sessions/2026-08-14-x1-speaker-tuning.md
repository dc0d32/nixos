# 2026-08-14 — X1 speaker tuning by ear, and what measurement could not settle

## User preferences locked in

> "take a look at the easyeffect presets. I like X1Yoga7-Dynamic-Detailed
> the most for pb-x1. Can you please review the preset and suggest any
> improvements?"

> "ok, let's play by the ear then. Revert your shenanigans, and let's vet
> the changes by me. How do you recommend we test this?"

> "add 3a and e1 as presets. I don't use any others. Those 20-something
> presets are useless"

> "we won't be installing any of it by default anywhere. We just don't
> want to re-do all the good stuff we did just now. a tool or library
> with dev shell is good"

Two process notes worth keeping. The user rejected a line of enquiry
outright — *"that's not a challenge. It is a directive. Move on"* — after
an unproductive detour into CPU fan noise; and twice caught contaminated
measurements from the other side of the room (*"it was my ceiling fan"*,
*"I was watching a video on this very laptop"*). Both were faster than
any diagnostic being run at the time. When a measurement looks wrong, ask
what else is making noise before building a better instrument.

## Outcome

`hosts/pb-x1/audio-presets/` went from 27 vendor presets to three, the
speakers are ~3 dB louder with bass enhancement and a voice-clarity lift,
and the internal microphone no longer clips on room noise. Details are in
`hosts/pb-x1/audio-presets/README.md` and `scripts/README.md`; this file
records why, and what was tried and abandoned.

## 1. The presets were giving away 3 dB

Every Dolby-derived preset padded `equalizer#0.output-gain` by -3 dB.
Measured against pink noise the chain landed 4.8 dB below bypass in RMS
while peaks still sat 4.4 dB below `limiter#0`'s -1 dBFS threshold — the
padding protected nothing. Corroboration: the `X1Yoga7-Voice-*` presets
already shipped from Lenovo at `-0.0`.

`autogain#0` was also in `plugins_order` with `bypass: true` on 24 of the
27 presets, and present as an orphan settings block on the other 3. A
bypassed EasyEffects plugin is still a live PipeWire filter node
(`ee_soe_autogain`), so removing it took a node out of the graph for free.

## 2. Acoustic measurement was attempted, and mostly failed

This consumed most of the session and produced one genuinely reusable
discovery, so it is worth recording in full.

**The internal microphone carries a DSP echo reference.** On this
SOF/DMIC machine the mic stream includes a digital copy of the playback.
Mute the speakers at the codec and a sweep *still records at full level*.
The tell was a measured "speaker response" flat within 2 dB from 150 Hz
to 14 kHz, which no laptop speaker is; the confirmation was that the
recorded level did not change when the speaker volume did.

It can be cancelled, because both paths are linear and share one sweep:

    H_acoustic = H_(speakers on) - H_(speakers off)

That gave 39-40 dB of cancellation. But even with a clean acoustic
measurement the microphone is uncalibrated and near-field, so the result
is speaker x mic and **cannot** be flattened — doing so would bake the
mic's own response into the speakers.

**Distortion could not be measured at all.** Two plausible-looking THD
curves were produced before both turned out to be artefacts: the first
tracked *microphone clipping* almost exactly, the second fell with level,
which is the signature of a noise-limited harmonic window. The mic's
dynamic range, already consumed by the loopback, left the measurement
noise-limited below -27 dBFS and clipping-limited above -21 dBFS. That
needs an external microphone.

**So the 500-1250 Hz scoop in the vendor IR remains unvalidated.** It is
directionally plausible — the driver does appear prominent around
630 Hz-1 kHz — but its depth cannot be judged with this equipment. It was
left alone, and `audio-presets/README.md` says not to "correct" it
without a real measurement mic.

Mistakes made along the way, all caught by checking rather than by
shipping: an inverted inverse-filter envelope sign (a clean -12 dB/oct
tilt that looked entirely plausible); a 450 ms analysis window that buried
the direct sound in reverb (4.21 dB rep-to-rep spread, vs 0.17 dB gated);
a stale hardcoded PipeWire node id that made `wpctl set-volume` fail
silently after a wireplumber restart; and `Master Playback Switch`
assumed to mute the speakers when only `Speaker Playback Switch` does.

## 3. Tuning by ear, with measurement as a guard rail

Once measurement could not answer the tonal question, the loop became:
build candidates, measure them *electrically* through the loopback
(silent, since the speakers stay muted) to confirm none of them clip or
ride the limiter, then have the user listen.

That produced the session's most useful number. Sorting every variant the
user auditioned by energy in the 81-182 Hz band relative to baseline:

| variant | 81-182 Hz | verdict |
| --- | --- | --- |
| amount 18 + shelf 4.5 | +10.6 dB | clean |
| amount 24, no shelf | +12.3 dB | clean |
| amount 22 + shelf 4.5 | +12.6 dB | distorts |
| amount 22 + shelf 5.25 | +12.9 dB | distorts |
| amount 24 + shelf 6.0 | +13.5 dB | distorts |
| amount 26 + shelf 4.5 | +15.1 dB | distorts |

**The driver breaks up between +12.3 and +12.5 dB in that band** — a
sharp mechanical limit. A compression test showed the chain itself barely
limits (0.32 dB), so the distortion is acoustic and cannot be fixed
downstream. Both shipped presets sit at +10.5 dB.

Three further findings:

- **`bass_enhancer` is not really a harmonic synthesiser here.** It works
  by saturating the low band, so it boosts the *fundamental* as well as
  the harmonics; and because music already has plenty of energy at
  200-600 Hz, the added harmonics barely move those bands. Its visible
  effect is low-frequency boost, which is exactly the excursion-limited
  thing that cannot be afforded.
- **`floor-active` matters, and the obvious direction is wrong.** Without
  a floor the exciter put ~+11 dB into 0-81 Hz, which these drivers
  cannot reproduce at all. `floor = 100` cut that to +3 dB *and*
  increased the useful harmonics. Raising the floor further is
  counter-productive — it moves the processed band up into the
  excursion-limited range.
- **Bass costs midrange if you are not careful.** Holding bass at the
  ceiling while pushing the exciter harder needs output compensation,
  which drags the mids down with it. One candidate landed 3 dB *below*
  baseline at 1-5 kHz; the user reported it as "lower sharpness" on
  voices before any measurement was run on it. `-Bass-Presence` exists to
  counter exactly that, and is the autoloaded default.

## 4. The microphone clips on room noise

Found while trying to use the mic as an instrument, then fixed on its own
merits. The UCM profile brings `Dmic0 Capture Volume` up at maximum
(+20 dB), where a ceiling fan alone pinned 0.96 % of samples at full
scale. `flake-modules/mic-gain.nix` sets it to +5 dB via a systemd
oneshot, re-applied on resume. It costs nothing in SNR — the control is a
digital gain after the ADC, so it scales signal and noise together and
only buys headroom.

## Decisions

**Presets edited in place rather than shipped as new `-Loud` files**, so
the autoload rule and preset list stay clean. They are no longer pristine
vendor exports, which `audio-presets/README.md` records — a re-extract
from the Windows driver would otherwise silently undo the work.

**24 presets and 26 IRs deleted** at the user's request. All three
survivors share `X1Yoga7-Dynamic-Detailed.irs`. The unmodified vendor
baseline was kept, both because the new presets derive from it and
because that IR is the only convolver kernel left — a binary that cannot
be regenerated without the Lenovo driver. Everything deleted is in git
history.

**The measurement rig was kept but installed nowhere.**
`scripts/{audio_ess,speaker-measure,preset-headroom}.py`, packaged in
`flake-modules/audio-tools.nix`, exist only in the devShell and as flake
packages; verified to have zero references in both the pb-x1 system
closure and the p@pb-x1 home closure. `preset-headroom` is the one likely
to earn its keep — it is pure offline, reproduces the numbers this work
was based on, and exits non-zero on a preset that rides the limiter,
which several candidates here did.

## Open

- **pb-t480 has never been validated.** Its presets are hand-EQ'd (no
  Dolby IR to extract) and `audio.autoloads` is still empty, so nothing
  is applied automatically. `preset-headroom` will check its gain staging
  offline today; the acoustic side needs the same loopback check, since
  whether that machine's DMIC has an echo reference is unknown.
- **The 500-1250 Hz scoop** stays unvalidated until there is a calibrated
  microphone.
- **Only `X1Yoga7-Bass-Presence` and `X1Yoga7-Bass` have been heard.** The
  +3 dB change was propagated to the other presets on modelling alone
  before most of them were deleted.

---

## Follow-up: the crackle (same session, later)

After living with `X1Yoga7-Bass-Presence` for a while the report came
back: *occasional crackling and clipping; turning off the second
equalizer makes it go away.* That turned out to be **two unrelated
faults** stacked on top of each other, and separating them took most of
the follow-up.

### Fault 1 — a click on the first sound after silence

Reproducible with every preset, with all presets disabled, and with
EasyEffects bypassed entirely: the first transient after roughly ten
seconds of quiet is preceded by a click. This is the HD-audio codec
powering down and waking back up — nixpkgs builds the kernel with
`CONFIG_SND_HDA_POWER_SAVE_DEFAULT=10`. Confirmed by

```sh
echo 0 | sudo tee /sys/module/snd_hda_intel/parameters/power_save
```

which removed it outright. **Deliberately not fixed declaratively.** It
is a known, understood, runtime-toggleable kernel default and not worth
trading the codec's idle power for; recorded here so the next person to
hear it does not spend an evening bisecting DSP presets like this one
did.

This fault is why the early rounds of the investigation went nowhere: it
fires on the first beat of every test clip, so every variant "crackled"
and no A/B could separate anything.

### Fault 2 — driver excursion at full volume

The real one, and the one the presets were guilty of. A critical wrong
assumption early on was that playback happened around 60% volume; it
does not, it is often at 100%. `multiband_compressor#1` — the vendor's
excursion limiter — works on the digital signal with fixed thresholds,
so it cannot see the analog volume and was far too permissive up there.
The digital output was verified clean at the time of the audible
crackle, which places the fault after the DAC: mechanical.

Fixed by lowering `band0/1/2` `attack-threshold` by 15 dB on both
`X1Yoga7-Bass` and `X1Yoga7-Bass-Presence`. Rationale and the reason
this beat simply reducing the bass shelf are written up in
`hosts/pb-x1/audio-presets/README.md`. A ladder of five candidates was
auditioned; the chosen one (15 dB) was the first that was fully clean —
the 12 dB step still crackled, and the user's verdict on the pair was
"P3 crackles, P4 is good balance without crackling".

### Process notes worth keeping

- **`amixer sset` does not work on these controls** ("Unable to find
  simple control") — `amixer cset name='...'` does. This silently
  no-op'd the speaker mute in `scripts/speaker-measure.py` for several
  rounds, meaning supposedly-silent measurement runs were audible and
  the measurements themselves were contaminated. Fixed in this commit,
  with a read-back verification that is fatal on mismatch. **Always read
  back after setting an ALSA control.**
- `Master Playback Switch` does not mute these speakers; only
  `Speaker Playback Switch` together with `Bass Speaker Playback Switch`
  do.
- PipeWire node IDs are reassigned when wireplumber restarts, e.g. after
  a suspend. A stale id makes `wpctl set-volume` fail with "does not
  support volume", which is invisible if the call's output is captured.
  Resolve nodes by `node.name` at call time.
- An early conclusion that "the presets were never broken" was wrong and
  was retracted. Fault 1 being real did not make fault 2 imaginary.

### Still open

`X1Yoga7-Bass*` bands 0-2 are now clamped hard. This was signed off on
synthetic test signals and a drum loop; it is worth confirming over time
that it does not flatten dynamics on real music. If it does, the
thresholds are the single knob to back off.
