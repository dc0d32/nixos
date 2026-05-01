# 2026-05-01 — T480 concretization (rename + nixos-hardware + battery)

Concretized the previously-named `family-laptop` host as the actual
hardware it lives on (Lenovo ThinkPad T480) and wired the first
hardware-aware feature module (battery / hibernate). The wiring
exposed a latent multi-laptop singleton-options bug that needed a
minor architecture change to fix correctly.

## What landed

Two commits on `main`:

| SHA | Title |
|---|---|
| `23397b3` | rename family-laptop host to pb-t480 |
| `96ebe15` | pb-t480: import nixos-hardware T480 + wire battery (multi-laptop refactor) |

## Decisions (asked, not assumed)

- **Hardware reveal.** User said the family laptop is actually a
  Lenovo T480 with the Intel UHD 620 + Nvidia MX150 Optimus SKU,
  with a working fingerprint reader but no IR camera.
- **Naming.** Rename `family-laptop` → `pb-t480` to match the
  pb-x1 scheme (initials + model). Keeps the door open for
  future ThinkPads (`pb-t14`, etc.) without re-cementing
  generics.
- **Scope of this session.** Land the rename + nixos-hardware +
  battery NOW. Defer GPU PRIME/Optimus, fingerprint/face
  biometrics split, and a T480 EasyEffects audio preset to
  follow-up commits because they need real hardware to validate
  or are bigger module refactors. Skipping the SSH-hardening
  work (deferred earlier).
- **Singleton fix scope.** When the wiring exposed the
  per-NixOS-config singleton problem on `battery.*`, asked
  whether to do the proper refactor (move options into the
  module body) or a tactical shim. User picked the proper
  refactor. Same question came up again for `idle.*` once the
  battery refactor exposed the cross-module read; same answer.

## What changed

### Commit 1: rename only

Pure rename, no behavior change. `git mv` preserved history:

- `hosts/family-laptop/` → `hosts/pb-t480/` (3 files)
- `flake-modules/hosts/family-laptop.nix` → `pb-t480.nix`
- Updated all in-tree comment / path references in working files:
  pb-t480.nix internals, AGENTS.md, mk-pkgs.nix, openssh.nix,
  zoom.nix, chromium-managed.nix, bundles/home-{desktop,kid}.nix,
  the placeholder hardware-configuration.nix self-references, and
  the chromium-policy.md title.

Past session notes under `docs/sessions/` were left untouched per
AGENTS.md ("Do not edit past session files"). They preserve the
historical naming at write time. The single remaining
`family-laptop` reference inside pb-t480.nix is a session-note
filename citation — also left intact because session-note
filenames don't change.

### Commit 2: nixos-hardware + battery + multi-laptop refactor

Hardware concretization on pb-t480:

- `flake.nix`: added `inputs.nixos-hardware =
  github:NixOS/nixos-hardware`. Locked at
  `2096f3f411ce46e88a79ae4eafcfc9df8ed41c61` (2026-04-23).
- `flake-modules/hosts/pb-t480.nix`:
  - Added `inputs` to the module signature.
  - Imported
    `inputs.nixos-hardware.nixosModules.lenovo-thinkpad-t480`
    (kernel modules, microcode, T480 quirks).
  - Imported `config.flake.modules.nixos.battery`.
  - Set battery values mirroring pb-x1 (chargeStop=80,
    chargeStart=75, criticalAction=Hibernate,
    powerSaverPercent=40, swapSizeGiB=32).
  - `resumeDevice` uses an all-zeros placeholder UUID with a
    `CHANGEME` comment. The existing `battery-resume-offset`
    systemd unit will print the right `boot.kernelParams` line
    on first boot of real hardware.

The multi-laptop singleton fix:

- `flake-modules/battery.nix`: moved `options.battery` from the
  flake-parts top level INTO the NixOS module body. Each NixOS
  config now has its own `battery.*` scope.
- `flake-modules/idle.nix`: same move — `options.idle` lifted
  from flake-parts top into the HM module body. Added
  `powerSaverPercent` to that option set (was previously
  cross-read from `config.battery.powerSaverPercent` at the
  flake-parts level, which only worked because singletons made
  every host's value globally visible).
- `flake-modules/hosts/pb-x1.nix`:
  - Relocated `battery = { … }` into
    `configurations.nixos.pb-x1.module`.
  - Relocated `idle = { … }` into
    `configurations.homeManager."p@pb-x1".module` and added
    `powerSaverPercent = 40` to preserve the previous TOML.
- `flake-modules/hosts/pb-t480.nix`: added `idle = { … }` into
  both `configurations.homeManager."p@pb-t480".module` and the
  shared `mkKidHmModule` (kids get the same lock/dpms/suspend
  timings as p; no `powerSaverPercent`, default 0 = disabled).

## Why the singleton bug existed

The host bridge `pb-x1.nix` already carried this comment, written
during the dendritic migration:

> NOTE: per-host values that are conceptually per-NixOS-config
> (hostname, primary user, system tuple, state version) are NOT
> set at the flake-parts level — they live inside the
> `configurations.nixos.${hostName}.module` block below. Setting
> them up here would create a flake-parts singleton that conflicts
> the moment a second host with different values shows up.

That comment correctly identified the danger but only applied it
to a small set of fields (hostname, user, system, stateVersion).
`battery.*`, `idle.*`, `audio.*`, `gpu.*`, `wallpaper.*`,
`locale.*`, `git.*` were all left at the top level — and most
will hit the same conflict the moment a second host wants
different values.

This commit fixes battery and idle (which were in the way today).
The remaining ones (`audio`, `gpu`, `wallpaper`, `locale`, `git`)
work today because either (a) only pb-x1 imports the consuming
module, or (b) every importing host happens to want the same
value. They'll need the same treatment opportunistically as
multi-laptop deltas appear.

### Pattern for future moves

1. In `flake-modules/<feature>.nix`: lift `options.<ns>` from the
   flake-parts top level into the body of
   `flake.modules.<class>.<feature>`.
2. In each host that sets `<ns>.* = …`, move the assignment from
   the flake-parts top level into the relevant
   `configurations.<class>.<id>.module` block.
3. Verify regression: `nix build` the unaffected hosts'
   closures and confirm the store paths are byte-identical to
   before the move.

## Regression verification

Smoke-built all 10 closures with
`NIXOS_ALLOW_PLACEHOLDER=1 nix build --impure --no-link
--print-out-paths …`:

| Closure | Pre-commit-1 path | Post-commit-2 path | Same? |
|---|---|---|---|
| pb-x1 toplevel | `0bgvbw6r…-nixos-system-pb-x1-…` | `0bgvbw6r…-nixos-system-pb-x1-…` | ✅ byte-equivalent |
| p@pb-x1 HM | `wnh6wni2g…-home-manager-generation` | `wnh6wni2g…-home-manager-generation` | ✅ byte-equivalent |
| wsl toplevel | `f8pc9csn7…-nixos-system-wsl-…` | `f8pc9csn7…-nixos-system-wsl-…` | ✅ byte-equivalent |
| ah-1 toplevel | `c6z80md0l…-nixos-system-ah-1-…` | `c6z80md0l…-nixos-system-ah-1-…` | ✅ byte-equivalent |
| p@wsl HM | `wq94h19pv…-home-manager-generation` | `wq94h19pv…-home-manager-generation` | ✅ byte-equivalent |
| nas@ah-1 HM | `ijc4a1jih…-home-manager-generation` | `ijc4a1jih…-home-manager-generation` | ✅ byte-equivalent |
| pb-t480 toplevel | `9h1i5pa99…` (commit-1 only) | `b133r8flz…` | ⚠ expected change (nixos-hardware + battery + initrd kernel modules from T480 module) |
| p@pb-t480 HM | (commit-1 only) | (changed) | ⚠ expected change (now has idle TOML) |
| m@pb-t480 HM | (commit-1 only) | (changed) | ⚠ expected change (now has idle TOML) |
| s@pb-t480 HM | (commit-1 only) | (changed) | ⚠ expected change (now has idle TOML) |

The byte-equivalence regression criterion holds for every host
that did NOT intentionally change. pb-t480 closures changed for
the deliberate reasons listed. ✅

## Deferred (separate future commits)

- **GPU Optimus PRIME**. `flake-modules/gpu.nix` only knows
  `intel | amd | nvidia | none`. T480 has Intel UHD 620 + Nvidia
  MX150 with PRIME/render-offload. Real fix needs
  `hardware.nvidia.prime.{intelBusId,nvidiaBusId}` filled in from
  `lspci -nn | grep -E 'VGA|3D'` on the actual machine, plus a
  module refactor to grow a `gpu.optimus = { … };` sub-option.
- **Biometrics split**. `flake-modules/biometrics.nix` is heavily
  X1-Yoga-specific: hardcodes the Synaptics Prometheus reader
  (X1 only) and unconditionally enables `services.howdy` (face
  auth via IR camera, which T480 doesn't have). Split into
  `fingerprint` + `face` sub-features so T480 can import
  fingerprint alone.
- **T480 EasyEffects preset**. Audio is X1-Yoga-specific today
  (preset + IRS files). T480 needs its own preset under
  `hosts/pb-t480/audio-presets/` and a wiring entry; same
  singleton-fix pattern will apply to `options.audio.*` since
  both hosts will then want different values.
- **Per-battery thresholds**. `battery.nix` only writes `BAT0`
  sysfs paths. T480 has BAT0 (external swappable, primary) +
  BAT1 (internal). BAT1 silently charges to 100% today.
  Splitting per-battery thresholds is a future enhancement —
  acceptable for v1 because the user-replaceable BAT0 is the one
  that matters most.
- **SSH hardening on ah-1**. From the earlier 9-step plan,
  three security questions remain dismissed.

## Files touched

Working files (committed):

- `flake.nix` — added nixos-hardware input
- `flake.lock` — locked nixos-hardware
- `flake-modules/battery.nix` — options scope refactor
- `flake-modules/idle.nix` — options scope refactor + powerSaverPercent
- `flake-modules/hosts/pb-x1.nix` — relocated battery/idle blocks
- `flake-modules/hosts/pb-t480.nix` — renamed + concretized
- 7 other working files updated in commit 1 for the rename
- 4 files renamed via `git mv` (3 under `hosts/family-laptop/` →
  `hosts/pb-t480/`, plus `flake-modules/hosts/family-laptop.nix`
  → `pb-t480.nix`)

Unchanged on purpose:

- `flake-modules/gpu.nix`, `flake-modules/biometrics.nix`,
  `flake-modules/audio.nix` — all need their own refactors
  later, deferred above.
- All files under `docs/sessions/` — immutable per AGENTS.md.

## Retire when

This note is historical and never gets edited. It stays useful
until both:

- The remaining flake-parts singleton options (`audio`, `gpu`,
  `wallpaper`, `locale`, `git`) have all been moved into per-
  config scopes (so the architecture rule the rename exposed is
  fully applied), AND
- T480 hardware concretization is done (real hwconfig, real
  resumeDevice UUID, GPU Optimus wired, biometrics split,
  audio preset).
