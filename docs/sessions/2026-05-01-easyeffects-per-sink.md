# EasyEffects: per-sink scoping via list-of-autoloads

Date: 2026-05-01.

## Context

Pre-fix state: `flake-modules/audio.nix` exposed a flat schema —
`audio.preset` (the global preset name) plus
`audio.autoloadDevice{,Profile,Description}` (a single autoload
target). The HM module wrote two things into `~/.config/easyeffects/`:

1. `autoload/output/<device>:<profile>.json` — the per-sink autoload
   rule. This part was always correctly per-sink: when the named
   PipeWire sink appears, EE applies the named preset to it.
2. `db/easyeffectsrc` — `[Presets] lastLoadedOutputPreset=<name>`.
   This is the **leak**: at EE startup it loads that preset against
   whatever sink is currently default, and it stays applied when the
   user later switches sinks (e.g. plugs in bluetooth headphones).
   The X1-Yoga-tuned preset (heavy multiband + convolver IRS for the
   built-in speakers) was therefore mangling bluetooth headphones too.

Goal: scope EasyEffects DSP strictly to the sinks the user has
configured a preset for; leave every other sink flat/passthrough.
Schema must be ready for the planned bluetooth-headphone preset
without a second migration.

Hosts in scope: pb-x1 only (the only host that imports the audio HM
module — its preset directory and IRS files are X1-Yoga-specific).

## Decisions

1. **Drop the `db/easyeffectsrc` write entirely.** EE 8.x has no
   "process all outputs" toggle; per-sink scoping is done entirely
   via autoload rules. With no global default written, sinks without
   an autoload entry stay flat/passthrough — which is exactly what
   we want for bluetooth, HDMI, USB DACs, etc. that haven't been
   profiled.
2. **Refactor to `audio.autoloads`, a list of submodules.** Each entry
   is `{device, profile, description, preset}` — one rule per sink.
   This replaces both `audio.preset` (no longer needed; preset is
   always associated with a sink) and the three flat
   `audio.autoloadDevice*` options (now folded into the submodule).
   The user authored this as the chosen path explicitly to avoid a
   second schema migration when adding the bluetooth-headphone
   preset later.
3. **No fallback / no implicit default.** Every preset must be
   explicitly bound to a sink. There is no "load this preset on
   whatever sink shows up" mode any more. This is a deliberate
   tightening: the previous flat schema made the implicit fallback
   easy to forget about, and the resulting global preset application
   was the bug we were fixing.
4. **Submodule (not raw attrset list).** The submodule type gives
   nix-level option docs + per-field type checking, so a typo in
   `device` / `profile` / `preset` fails at evaluation rather than
   producing a silently-broken autoload rule JSON.

## Implementation

Single commit `f88b9a8`:

`flake-modules/audio.nix`:
- Replace four top-level options (`audio.preset`, `audio.autoloadDevice`,
  `audio.autoloadDeviceProfile`, `audio.autoloadDeviceDescription`)
  with one: `audio.autoloads` (`listOf submodule`, default `[]`).
- HM autoload generation moves from `xdg.dataFile` (it was using
  `lib.optionalAttrs` against the single rule) to `xdg.configFile`,
  built via `lib.listToAttrs (map ... cfg.autoloads)` — one
  `easyeffects/autoload/output/<device>:<profile>.json` per list
  entry.
- Delete the `xdg.configFile."easyeffects/db/easyeffectsrc"` block
  entirely. No global `lastLoadedOutputPreset` write.
- Update the file header to document the per-sink scoping rule and
  why we deliberately don't write a global default.

`flake-modules/hosts/pb-x1.nix`:
- Replace the four-line flat audio config with a single-entry
  `autoloads` list (the existing X1 Yoga speaker rule). Comment
  points at the same `wpctl inspect` recipe as before, plus a hint
  about how to add a second entry for bluetooth headphones
  (`device = "bluez_output.<MAC>.1"`).

Note: autoload rules now live under `xdg.configFile`, not
`xdg.dataFile`. EasyEffects expects them at
`~/.config/easyeffects/autoload/output/`, not under `~/.local/share/`
(presets and IRS are still under `~/.local/share/`). The previous
schema mistakenly listed the autoload rule alongside presets in
`xdg.dataFile`; output verification now confirms the rule lands in
the correct location.

## Verification

Smoke-built all 10 closures with `NIXOS_ALLOW_PLACEHOLDER=1
nix build --impure`. All 9 unrelated closures byte-identical to
pre-refactor baseline; only `p@pb-x1` HM changed
(`qp4frnbkcc1jhybigwjsvmx63f83j253`), as expected — it's the only
HM that imports `flake.modules.homeManager.audio`.

Inspecting the new closure on disk:

- `~/.config/easyeffects/autoload/output/alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink:Speaker.json`
  — present, content matches the X1 Yoga rule.
- `~/.config/easyeffects/db/` — directory does not exist (correct;
  EE will create it itself for per-plugin user state, and the global
  preset selection key is no longer nix-managed).

Activation on pb-x1 still pending (user to run `home-manager
switch --flake .#'p@pb-x1'` then `systemctl --user restart
easyeffects`). Behavioral validation requires plugging in a
bluetooth headset and confirming it plays without the X1 Yoga
preset's convolver/multiband applied.

## Follow-ups

- **Author the bluetooth-headphone preset.** Capture a flat baseline
  through the user's WH-1000XM4 (or whichever target headset),
  measure with REW or sweep tones, build a corrective EQ + safety
  limiter preset. Add a second entry to `audio.autoloads` with the
  bluez sink node-name (`bluez_output.<MAC>.1`) and the new preset
  name. No further code changes needed — the schema is already
  multi-rule.
- **Consider per-headphone presets.** If multiple bluetooth headsets
  see regular use, each can have its own autoload entry — the
  bluez sink node-name embeds the MAC, so they don't collide.
- **Closes the "Wire bluetooth audio into EasyEffects" item** flagged
  in `2026-05-01-bluetooth-stack.md` — bluetooth audio is now
  *correctly excluded* from the X1 Yoga preset. Adding a dedicated
  bluetooth preset is the next half of that follow-up, but no longer
  blocked on schema work.
