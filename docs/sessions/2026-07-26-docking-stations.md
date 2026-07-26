# 2026-07-26 — Docking stations: external displays and peripherals

## Context

s reported that plugging a dock into pb-t480 was a "pathetic" plug-and-play
experience. The investigation started from the wrong hypothesis and only
converged because the same dock was attached to pb-x1 for live testing.

## User preferences locked in this session

- **Support all dock families, not just the one that happened to be on the
  desk.** Thunderbolt 3, Thunderbolt 4, and DisplayLink. The fix must not be
  specific to whichever dock triggered the complaint.
- **Windows-grade UX is the bar**: monitors come up, and layout/resolution/
  scaling can be changed live.
- **Keep the config-driven approach** — that is explicitly "our whole thing"
  and must not be sacrificed for convenience.
- **wdisplays chosen as the middle ground** between pure-Nix (rebuild to
  change anything) and fully ad-hoc.

## The misdiagnosis, and why it matters

Initial reading of the symptoms pointed at Thunderbolt: both TB domains on
pb-x1 sit at `security = user`, and no `boltd` existed anywhere in the flake.
That was a real bug, but it was **not** s's bug.

Live capture with the dock attached showed:

```
Bus 002 Device 006: ID 17e9:6015 DisplayLink ThinkPad Hybrid USB-C with USB-A Dock
```

No Thunderbolt device enumerated at all — only the two Intel host
controllers. The dock is **DisplayLink**: video is compressed and pushed over
plain USB bulk transfers to a DL-6xxx ASIC.

The failure mode is what made this so misleading:

| Function | Status before this session |
|---|---|
| USB hub | worked |
| Gigabit ethernet (`r8152`) | worked |
| Audio (auto-switched to dock sink) | worked |
| **Video** | **completely dead** |

Everything except the monitors worked, which reads like a compositor or
monitor problem rather than a missing driver. The kernel log during a plug
showed 19 USB devices enumerating and `carrier on`, with **zero** `drm`,
`evdi` or `displaylink` lines.

**Lesson: test on the actual hardware before designing the fix.** A
`boltd`-only change would have shipped and helped s not at all.

## What was built

Four modules, all opt-in per host ("importing IS enabling").

### 1. `overlays/displaylink.nix`

`pkgs.displaylink` is unfree *and* non-redistributable, so nixpkgs sources it
via `requireFile` — the zip must be manually placed in each host's store
before it will build. That is incompatible with how this flake deploys:
`nixos-anywhere` builds the closure on a machine that has never seen the
target, and `auto-upgrade` rebuilds unattended (a `requireFile` miss is a hard
eval failure, so a laptop would silently stop upgrading).

Decision: swap the source for a `fetchurl` from the public Synaptics URL that
nixpkgs itself prints in its `requireFile` message. Verified the download
hashes to exactly nixpkgs' expected value. Configuring a host to install
DisplayLink is the act of accepting the EULA.

The overlay carries a **version assertion**: the URL is version-pinned
(`2025-09`, 6.2.0-30), so if nixpkgs bumps `displaylink` the overlay throws
with refresh instructions rather than silently pairing a new `evdi` with a
stale userspace driver.

Caveat recorded in the file: the closure is non-redistributable and must never
be pushed to a shared binary cache.

This is the repo's first overlay; `overlays/default.nix` was an empty list.

### 2. `flake-modules/displaylink.nix`

Deliberately **not** an import of nixpkgs' `hardware/video/displaylink.nix`.
That module is X11-shaped: gated on `services.xserver.videoDrivers`, and its
body emits an `xorg.conf.d` OutputClass, sets `externallyConfiguredDrivers`,
and hangs `xrandr --setprovideroutputsource` off
`displayManager.sessionCommands`. These hosts are Wayland-only, so importing
it would switch on an X server we never run to reach three relevant lines.

Reproduced only the Wayland-relevant parts: `evdi` in `extraModulePackages` +
`kernelModules`, the udev rules, and `dlm.service`. Notably `dlm.service` is
**not** `wantedBy` anything — the shipped udev rule
(`ATTRS{idVendor}=="17e9"` → `SYSTEMD_WANTS="dlm.service"`) starts it on
demand, so no proprietary daemon runs while undocked.

**Fixed a genuine bug in nixpkgs' suspend hooks along the way.** They
read/write `/tmp/PmMessagesPort_{in,out}` unguarded. Those FIFOs don't exist
until the host has docked at least once, so the redirect exits non-zero and
fails `sleep-actions` — which is ordered `before sleep.target` — on *every*
suspend of an undocked laptop. Worse, opening a FIFO for writing blocks until
a reader appears, so a stale FIFO from a dead daemon would hang suspend
indefinitely. Now guarded with `[ -p … ]` and bounded with `timeout`.

### 3. `flake-modules/thunderbolt.nix`

Covers the dock family s's dock happens not to be, per the explicit
requirement.

The key finding is from `boltd(8)`: when the platform advertises
`iommu_dma_protection` on the domain, boltd **auto-enrolls and authorizes new
devices with no user interaction**. That is exactly Windows' Kernel DMA
Protection model — the authorization prompt exists to stop a DMA attack, and
the IOMMU already stops it.

This splits the two laptops:

| | pb-x1 | pb-t480 |
|---|---|---|
| Controller | Alder Lake (TB4) | Alpine Ridge (TB3, 2018) |
| `iommu_dma_protection` | 1 (verified live) | absent |
| Behaviour | silent auto-authorize | `auth_admin` prompt |
| `thunderbolt.trustLocalUsers` | `false` | `true` |

On pb-x1, enabling boltd is the entire fix. On pb-t480 it is not: all three
bolt polkit actions default to `auth_admin`, and m/s are deliberately
non-wheel, so without the rule a dock is **permanently unusable** for the
accounts that use that laptop most.

`trustLocalUsers` is declared as a **NixOS-module** option, not a flake-parts
top-level one — following the `hardware-hacking.extraUsers` precedent, since a
top-level option would leak the loosened policy onto pb-x1.

**Trade-off accepted and documented**: on pb-t480 this lets someone with
physical access authorize a malicious TB device and DMA host memory without an
admin password. A logind session counts as "active" while the screen is
locked. The alternative — a dock that doesn't work for its main users — was
judged worse. The firmware fallback if this is ever reconsidered is
`security=dponly` (DP tunnels work, no PCIe).

### 4. `flake-modules/displays.nix`

Before this, the entire display config in the flake was
`outputs = { "eDP-1".scale = 1; }`. Nothing for external monitors, no memory
of a layout between plug events, and no way to correct it without editing Nix
— which the kid accounts cannot do.

Two layers:

1. **Declarative** `displays.outputs` — the known-good layout, in git.
2. **Mutable** `~/.config/niri/outputs.local.kdl` — written by `display-save`
   after rearranging in wdisplays. No rebuild, no sudo.

Plus `display-export` (prints the current arrangement as a Nix snippet to
promote into a host bridge) and `display-reset` (discard the mutable layer).
Bound `Mod+D` (wdisplays) and `Mod+Shift+D` (save).

**No kanshi.** niri matches `output` blocks by connector name *or* by
`"MAKE MODEL SERIAL"` and re-applies all output config from scratch on every
hotplug — kanshi's whole feature set, in-compositor. Adding kanshi would mean
two daemons fighting over wlr-output-management.

Layouts are keyed by **make/model/serial**, not connector: connector numbering
depends on which physical port a dock routes a monitor through, so the same
monitor can be `DP-2` today and `DP-4` tomorrow.

#### The ordering trap (most valuable finding)

niri's docs say includes are *"positional. They will override options set
prior to them"* — i.e. last-wins. **That is false for `output` blocks.** They
are a "multipart section ... inserted as is without merging", and lookup is
`self.0.iter().find(...)` (`niri-config/src/output.rs:150`) — a linear scan
returning the **first** match.

Verified empirically with a nested winit niri instance, two configs differing
only in include order:

```
include "local.kdl"; include "base.kdl";   ->  scale 3   (local wins)
include "base.kdl";  include "local.kdl";  ->  scale 1   (base wins)
```

So the mutable include is **prepended**, in `niri.nix` (which owns
`programs.niri.config`), gated on a `displays.enable` cross-module signal.
Get this backwards and saved layouts are silently ignored — file written, no
error anywhere, nothing changes.

Also worth recording: niri-flake's schema differs from raw KDL — it uses
`enable` (default true) not `off`, `transform` is a record
`{ flipped, rotation }` not a string, and `variable-refresh-rate` is an enum
`false | "on-demand" | true`. Read from `settings.nix:1808-1910`, not guessed.

### 5. Wallpaper on hotplug (`flake-modules/wallpaper.nix`)

awww paints per-output and has no notion of monitors appearing later, so a
freshly-attached screen kept a flat colour until the next timer tick — up to
`intervalMinutes` of grey. Observed live.

Added `wallpaper-apply` (re-applies the *current* image only to outputs
showing a solid colour — deliberately does not fetch, so hotplug never burns a
Wallhaven call or changes the image) plus a `wallpaper-hotplug` user service
watching `niri msg event-stream`.

Triggers on `Workspaces changed` rather than an output-specific event: niri
always moves workspaces when an output appears or disappears, so it is a
reliable proxy that exists in the stable IPC surface. The apply script is
cheap and idempotent, so extra triggers cost nothing.

### 6. Persisting saved layouts (`flake-modules/impermanence.nix`)

pb-t480 wipes `/` on every boot, so a layout saved by a kid would have
vanished at reboot — the exact papercut this session exists to remove. Added
`.config/niri/outputs.local.kdl` to `impermanence.userFiles`.

Persisted as a **file**, not by adding `.config/niri` to `userDirectories`:
home-manager owns `config.kdl` in that directory as a read-only store symlink
and rewrites it every generation, so bind-mounting the whole directory would
fight HM for it.

That surfaced a latent hazard in the existing de-shadow logic, which merges a
shadowing file into the persisted one as a line-union
(`cat "$src" "$target" | awk '!seen[$0]++'`). That is correct for append-style
shell history and actively destructive for a structured document: two KDL
layouts concatenated yield duplicate `output` blocks, which niri rejects —
taking the user's whole desktop config down over a saved monitor layout.

Added `impermanence.userFilesAppendOnly` (default `[".zsh_history"]`) to make
the strategy explicit. Files not listed get their shadowing copy moved to
`<name>.shadow-<timestamp>` with the persisted copy winning — lossless, and no
invalid file is ever produced. Verified in the built system: all three users
get a persist unit, `.zsh_history` maps to `merge`, and the layout file to
`aside`.

## Verification

Live on pb-x1 with the dock attached:

- `card0` (evdi) appeared; niri enumerated
  `Samsung Electric Company C32R50x H1AK500000` at 1920x1080@60 with the full
  EDID mode list and created a workspace on it.
- `grim -o DVI-I-1` captured a genuinely composited desktop (waybar + video
  playback) — rendering, not merely enumerated.
- `display-save` / `display-export` / `display-reset` all exercised.
- `wallpaper-apply` tested by blanking DVI-I-1: repainted it and correctly
  left eDP-1 alone.
- User confirmed the wdisplays workflow works after `home-manager switch`.

`nix flake check --impure` passes. Both p and s build on pb-t480, and s
(non-wheel) gets all four display tools and an identical niri config.

## Gotchas worth remembering

1. **`boot.extraModulePackages` does not take effect on `switch`.** After the
   first rebuild adding this module, `evdi.ko` was in
   `/run/current-system/kernel-modules` but not `/run/booted-system/...`,
   which is what `/lib/modules` (and therefore modprobe) resolves to.
   `systemd-modules-load` logged `Failed to find module 'evdi'` and the
   monitors stayed dark despite a correct build. **A reboot is required on
   first deployment.** To verify without one (same kernel version):
   `sudo modprobe -d /run/current-system/kernel-modules evdi`.

2. **`nix fmt` with no path argument hangs.** `formatter.nix` binds
   `formatter = pkgs.nixpkgs-fmt`, a bare package, so nix passes no paths and
   nixpkgs-fmt blocks reading stdin. Use `nix fmt .` or explicit files.

## Follow-ups not done

- pb-t480 lists no external monitors in `displays.outputs` — deliberate.
  Whoever docks should arrange with wdisplays and `display-save`, then
  promote with `display-export` once a good layout settles.
- The Thunderbolt path is built and evaluated but has **not** been exercised
  against a real TB3/TB4 dock; only the DisplayLink path is live-proven.
- EasyEffects `autoloads` don't match the dock's audio sink (cosmetic; dock
  audio already works via PipeWire's default switching).
