# 2026-08-04 — EasyEffects: scope presets to built-in speakers only

## User preference locked in

> "can we have easy effects preset trigger and enable only for laptop
> speakers on t480, pb-x1 etc? For bluetooth, HDMI, dock connections,
> let's keep default audio profile (so disabled I guess)."
>
> "to be clear, I want the preset to turn off when I connect my BT
> headphones, and turn back on when I switch to laptop speakers+mic"
>
> "we may add a preset for mic later btw"

> "easyeffect itself has a way to trigger presets, at least i remember
> there was a way to do this in GUI when i was using debian last year"

Correct — EasyEffects' Presets window has an **Autoloading** tab
(per-device profiles plus a *fallback* preset). This session wires that
native mechanism declaratively; nothing custom was invented.

## What was actually broken

Two independent defects, both verified on live pb-x1 against EasyEffects
8.2.4.

### 1. Autoload rules were written to the wrong directory

`flake-modules/audio.nix` deployed rules via `xdg.configFile` to
`~/.config/easyeffects/autoload/output/`. EasyEffects 8.x builds that
path from `QStandardPaths::AppDataLocation`, i.e.
`~/.local/share/easyeffects/autoload/output/`
(`presets_directory_manager.cpp:45`).

EE ships an `xdg_migration()` that copies a legacy config-side tree into
the data dir. It succeeded exactly once (2026-06-14) and has failed on
every start since:

```
util.cpp:109  Copy Error: Failed to copy …/.config/easyeffects/autoload/output/…json
              to …/.local/share/easyeffects/autoload/output/…json. Reason: Permission denied
presets_directory_manager.cpp:146  Aborting migration
```

`std::filesystem::copy_file` preserves the source mode, and the source
was a nix-store symlink → the copy landed as `0444`, so the *next*
migration could not overwrite it. The effective autoload rule was frozen
at its first-ever value; every subsequent `home-manager switch` was a
silent no-op.

### 2. No fallback → the preset leaked onto every other device

`AutoloadManager::load()` (`presets_autoload_manager.cpp:165-190`)
returns **without touching the pipeline** when no rule matches, unless
the fallback is enabled. EasyEffects runs a single output pipeline bound
to the current device, so the built-in speaker's EQ *and its speaker
convolver IR* stayed applied after switching to bluetooth/HDMI/dock.

Live evidence before the fix:

```
[StreamOutputs]
outputDevice=bluez_output.00_06_78_47_46_E5.1
plugins=convolver#0,stereo_tools#0,equalizer#0,equalizer#1,autogain#0,…
[EffectsPipelines]
bypass=true          # ← the manual workaround
```

## Decisions

**Use EE's own fallback preset, not a custom supervisor.** Ship a
generated `Passthrough` preset (`plugins_order: []`, `blocklist: []`) and
point `output/inputAutoloadingFallbackPreset` at it. Any device without
an explicit rule now loads an *empty* chain, which is exactly "default
audio profile, DSP off". Rejected alternatives: enumerating every
bluetooth MAC (unbounded), and driving EE over D-Bus from a udev/PipeWire
hook (reimplements what upstream already does).

**Deploy everything through `xdg.dataFile`.** Presets, IRS *and* autoload
rules. Never `xdg.configFile` for EasyEffects — see defect 1. An
activation sweep deletes the unwritable leftovers (HM's own entries are
symlinks and hand-made GUI rules are `0644`, so both survive) and the
legacy config-side tree that keeps re-triggering the migration.

**Seed `easyeffectsrc` imperatively, with the daemon stopped.** The file
cannot be a store symlink: EasyEffects rewrites it constantly (window
geometry, most-used presets, current device). So the activation script
sets just our keys with `kwriteconfig6`.

The stop-then-start dance around that write is **not** optional.
`main.cpp`'s `SignalHandler` catches SIGTERM and calls
`QCoreApplication::quit()`, so a graceful shutdown runs
`db::Manager::~Manager()` → `saveAll()` → the whole in-memory settings
tree is written back. Writing first and restarting after would lose the
keys on the way down. Ordering is
`entryBetween [ "reloadSystemd" ] [ "linkGeneration" ]` so the preset
files exist before the daemon comes back up.

`systemctl` is **not** on home-manager's activation PATH; it must be
referenced by store path (`lib.getExe' pkgs.systemd "systemctl"`) or the
whole block silently no-ops with `systemctl: command not found`.

**Reset the global bypass on activation** (`audio.clearBypass`, default
true). Scoping is handled by autoload rules now, so a sticky global
bypass — the usual manual workaround for this exact bug — would just
disable DSP everywhere.

**Symmetric input support** for the mic preset the user plans to add
later: `inputPresetsDir`, `inputAutoloads`, `inputFallbackPreset`. Adding
a mic preset is now pure data in the host bridge.

## The `profile` field is a route description, not a card profile

EasyEffects keys the rule filename on
`node.device_route_description`, which `pw_manager.cpp:284` fills from
the PipeWire **Route** param's `description` — "Speaker", "Headphones",
"Digital Microphone". It is *not* `device.profile.name`
("HiFi: Speaker: sink"), which `scripts/audio-discover.sh` was printing.
That script has been rewritten to resolve the route out of `pw-dump`
(node → `device.id` + `card.profile.device` → matching Route), with
`device.profile.description` and a node-name-suffix guess as fallbacks.
It now emits entries for both the default sink and the default source.

pb-x1's existing rule (`profile = "Speaker"`) happened to be correct;
the comment in `pb-t480.nix` suggesting `profile = "analog-stereo"` was
not, and has been corrected.

## Verification

Live on pb-x1, `easyeffects --hide-window --debug`, watching both the
log and the `ee_soe_*` PipeWire filter nodes. A `module-null-sink` was
used as the "unlisted device" — note that `wpctl set-default <hdmi>`
does **not** work as a test when the HDMI port is unplugged: WirePlumber
updates `default.configured.audio.sink` but never `default.audio.sink`,
and EE only listens to the latter (`pw_metadata_manager.cpp:94`).

| default sink | log | `ee_soe_*` nodes |
| --- | --- | --- |
| built-in Speaker | `Autoload local preset X1Yoga7-Dynamic-Detailed` | 10 (full chain) |
| unlisted sink | `Autoload fallback preset Passthrough` | 2 (meters only) |
| back to Speaker | `Autoload local preset X1Yoga7-Dynamic-Detailed` | 10 (full chain) |

The built-in mic also correctly resolves to the input `Passthrough`
fallback.

`nix flake check --impure` passes; `p@pb-x1`, `p@pb-t480`, `m@pb-t480`
and `p@m-pc` all build.

## Follow-up

pb-t480 still has `autoloads = [ ]`, so *every* output there — including
the built-in speakers — gets `Passthrough`, which matches the previous
behaviour (T480-Music/T480-Voice were never auto-applied). Run
`./scripts/audio-discover.sh` on the T480 and paste the emitted entry
with `preset = "T480-Music"` to finish the job.
