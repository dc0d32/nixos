# 2026-06-27 — rethink power management fleet-wide: adopt TLP, drop PPD

## Trigger

The T480 felt slow; its i7-8650U was pinned near 0.9 GHz on a healthy
battery. Root cause was a latched `power-saver` profile in
power-profiles-daemon (PPD persists its active profile to
`/var/lib/power-profiles-daemon/state.ini` and re-applies it on every
daemon start — each `nixos-rebuild` restarts it — with no auto-restore).
A live `powerprofilesctl set balanced` fixed it (idle 400 MHz → sustained
3.2 GHz all-core, verified by load test), but that exposed a deeper mess.

## What was actually wrong (the audit)

Power management had drifted into three half-overlapping mechanisms, none
of which did automatic AC↔battery switching:

- **PPD did nothing useful.** Verified against the power-profiles-daemon
  0.30 source: its "BatteryAware" feature does NOT switch to the
  power-saver profile on low battery. It only swaps the intel_pstate EPP
  hint *within the balanced profile* (`balance_performance` on AC /
  `balance_power` on battery — `ppd-driver-cpu-intel-pstate.c`
  `profile_to_epp_pref`). There is no PercentageLow→power-saver trigger
  anywhere in PPD. (An earlier repo comment and a stored memory both
  claimed otherwise; both corrected/downvoted.)
- **TLP was suppressed.** nixos-hardware's laptop profile sets
  `services.tlp.enable = mkDefault (!services.power-profiles-daemon.enable)`,
  so enabling PPD silently kept TLP — the tool nixos-hardware *wants* on
  these ThinkPads — turned off.
- **The actual "conserve on battery" feature was gone.** It lived in the
  bespoke `idled` Rust daemon (retired 2026-06-22), then a hand-rolled
  `battery-power-saver` HM timer, then was deleted outright (commit
  2463ba7) on the mistaken belief PPD did it natively.
- `power.nix` claimed "tlp if laptop" in a comment but enabled neither
  TLP nor auto-cpufreq.

A brief detour wired in TuneD/tuned-ppd (keeps the PPD D-Bus API +
`battery_detection` auto-switching). It built, but on reflection the user
asked to rethink the whole thing and adopt a robust, proven solution.

## Decision

**TLP on the laptops; drop power-profiles-daemon (and the tuned detour)
fleet-wide.** TLP is the decade-old, ThinkPad-grade standard and does
automatic AC↔battery switching natively (CPU EPP, turbo, PCIe ASPM,
Wi-Fi power save, USB autosuspend, runtime PM). Nothing on niri consumed
the PPD D-Bus API / `powerprofilesctl`, so dropping the manual
performance/balanced/power-saver toggle costs nothing real. TLP is
deterministic from `/etc` config + AC state — it has no latchable runtime
profile, so the original footgun cannot recur.

Host taxonomy (power-relevant):

| Host    | Type            | Power stack                         |
|---------|-----------------|-------------------------------------|
| pb-x1   | X1 Yoga laptop  | TLP (+ thermald, battery.nix)       |
| pb-t480 | T480 laptop     | TLP (+ thermald, battery.nix)       |
| m-pc    | SFF desktop     | kernel governor + thermald          |
| ah-1    | VM (headless)   | none (unchanged)                    |
| pb-mb   | macOS (HM-only) | n/a (unchanged)                     |
| wsl     | WSL (headless)  | none (unchanged)                    |

## What changed

- **New `flake-modules/tlp.nix`** — `services.tlp` with vetted defaults
  plus a few intent knobs: EPP `balance_performance` on AC /
  `balance_power` on battery (deliberately NOT `power`, which is what
  pinned the CPU at min freq), turbo available on both with dynamic boost
  off on battery, Wi-Fi power-save and PCIe ASPM on battery. Imported by
  the **laptop bridges only** (pb-x1, pb-t480), NOT the workstation
  bundle (m-pc is a desktop). TLP is configured to NOT manage charge
  thresholds, so battery.nix stays their single owner.
- **`niri.nix`** — removed `services.power-profiles-daemon.enable`; PPD is
  dropped fleet-wide. upower stays (battery status + hibernate). Once PPD
  is off, nixos-hardware auto-enables TLP on the ThinkPads.
- **Reverted the TuneD detour** — deleted `flake-modules/tuned.nix` and
  its workstation-bundle wiring.
- **`battery.nix`** — unchanged behaviour (charge thresholds via sysfs +
  UPower hibernate-on-critical); header rewritten to point active power
  management at TLP and record the PPD findings as history.
- **`power.nix`** — comment fixed; it now clearly owns only thermald +
  generic `powerManagement` (CPU policy is TLP on laptops / kernel
  governor on the desktop).
- **`impermanence.nix`** — simplified the power-daemon-state note (TLP is
  config-driven; nothing to persist or latch).
- Comment fixes in `idle.nix` and `hosts/pb-x1.nix`.

## Resolved state (eval-verified)

| Host    | tlp.enable | power-profiles-daemon.enable | thermald |
|---------|-----------|------------------------------|----------|
| pb-t480 | true      | false                        | true     |
| pb-x1   | true      | false                        | true     |
| m-pc    | false     | false                        | true     |

## Verification

- `nix build` green: pb-x1, pb-t480, m-pc `system.build.toplevel`.
- `NIXOS_ALLOW_PLACEHOLDER=1 nix flake check --impure` — all checks
  passed (bash-shebang hook + every host + all HM configs).
- Pre-redesign live load test (post `set balanced`) confirmed healthy
  silicon: idle 400 MHz, sustained 8-thread 3.1–3.2 GHz, peak 3.7 GHz,
  temps to ~95 °C (under Tjmax), clean idle recovery.

## Apply / functional test

`sudo nixos-rebuild switch --flake .#pb-t480` (and `.#pb-x1`). Then:
1. `tlp-stat -s` — TLP active, mode reflects AC vs battery.
2. `tlp-stat -p` — on battery: EPP `balance_power`, dynamic boost off; on
   AC: `balance_performance`, boost on.
3. `tlp-stat -b` — charge thresholds still honoured (battery.nix owns
   them; TLP reports but doesn't manage them).
4. Confirm `powerprofilesctl` is gone (expected — PPD removed).

## Notes / possible follow-ups

- Charge thresholds could later move from battery.nix's sysfs writes into
  TLP (`START/STOP_CHARGE_THRESH_BATx`) for a single owner, but the
  current split (battery.nix = thresholds + hibernate, TLP = power policy)
  is clean and lower-risk, so left as-is.
- ah-1 / pb-mb / wsl intentionally untouched (no Linux laptop power).

## Follow-up (same session): self-healing impermanence de-shadow

Applying the power switch via `nixos-rebuild switch` surfaced an unrelated
latent bug: `persist-persist-home-s-.zsh_history.service` failed with "A
file already exists at /home/s/.zsh_history!" (exit 4). The power changes
applied fine — `tlp` active, PPD gone — but the failed unit made the
switch return non-zero.

Root cause: `/home` is its own btrfs subvol that survives the root
rollback, yet impermanence *also* bind-mounts per-user dotfiles from
`/persist` (so they land in the restic backup). If a real file is written
into `/home` before its bind mount is established (a kid logged in while
the mount was failing), impermanence's `mount-file` refuses to mount over
it — self-perpetuating.

Fix: a new `system.activationScripts.deshadowPersistedHomeFiles` in
`flake-modules/impermanence.nix`. For every normal user × `userFiles`
entry it relocates any shadowing real file into `/persist` (line-union
merge, so shell history is never lost), then restarts any unblocked
`persist-*` unit. Because switch-to-configuration runs activation scripts
*before* it (re)starts units, the next `nixos-rebuild switch` self-heals —
no manual cleanup needed, and it converges the boot path too.

Verified: pb-x1/pb-t480/m-pc build green; `nix flake check --impure`
passes; generated calls confirmed for users m/p/s
(`deshadow_file /home/<u>/.zsh_history /persist/home/<u>/.zsh_history`).

## Pivot (same session): battery%-aware matrix needs PPD + a watcher, not TLP

The user then specified an exact policy that TLP cannot express — a
four-state matrix gated on a 20% battery threshold:

|              | on AC       | on battery  |
|--------------|-------------|-------------|
| battery ≥20% | performance | balanced    |
| battery <20% | balanced    | power-saver |

plus charge-stop at 80% (already configured). No maintained tool does
*percentage-based* profile switching (PPD/tuned/TLP/auto-cpufreq are all
AC-vs-battery only), but the matrix maps cleanly onto PPD's three named
profiles. So TLP was removed and replaced with:

- **New `flake-modules/power-profile-auto.nix`** — enables
  power-profiles-daemon and adds a small UPower-driven watcher:
  - script reads `OnBattery` + DisplayDevice `Percentage` via `busctl`
    (aggregates the T480's dual battery; handles USB-C PD/docks),
    computes the matrix, and `powerprofilesctl set`s the result (only when
    it differs);
  - `power-profile-auto.service` (oneshot) + `.timer`
    (OnBootSec=30s, OnUnitActiveSec=60s) for the discharge-time 20%
    crossing, + a `power_supply` udev rule for instant AC plug/unplug;
  - a polkit rule granting root the `switch-profile`/`hold-profile`
    actions (PPD's defaults only allow *active* sessions, so the root
    service would otherwise be denied).
  - Imported by the laptop bridges (pb-x1, pb-t480) only.
- TLP module deleted; PPD re-enabled (per-laptop, via this module);
  comments in niri/battery/power/idle/impermanence/pb-x1 updated back to
  the PPD+watcher reality.

Why this is latch-safe: the watcher re-asserts the correct profile on
every power event and every 60 s, and PPD's state dir stays out of
impermanence — a stale `power-saver` can never persist.

Verified: pb-x1/pb-t480/m-pc build green; `nix flake check --impure`
passes; live read-only test on pb-t480 (AC, 76%) computes `performance`
as specified; polkit/udev artifacts confirmed.
