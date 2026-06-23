# 2026-06-22 — retire custom `idled`, switch to `swayidle`

## Why

The lockscreen kept rejecting the correct password. Two layers:

1. **PAM pollution** (fixed 2026-06-18): `services.{fprintd,howdy}.enable`
   inject `pam_fprintd`/`pam_howdy` into every PAM service; swaylock
   inherited a stack where howdy clobbered `PAM_AUTHTOK`. Fixed by
   forcing fprintAuth/howdy off for swaylock.

2. **The real, remaining cause — `idled`'s sandbox.** Even with a clean
   `pam_unix → deny` stack, the password was still rejected when the
   locker was spawned by the idle daemon. Root cause: `idled` ran as a
   systemd user service with `NoNewPrivileges = true`. A locker spawned
   as its child inherits `no_new_privs`, and the kernel then **ignores
   the setuid bit** on `unix_chkpwd` (the helper `pam_unix` uses to read
   `/etc/shadow` as a non-root process). So `pam_unix` couldn't verify
   the password → "authentication failure / invalid credentials". This
   is why `su` worked (no sandbox), a `Super+Alt+L` lock worked (spawned
   by niri, no sandbox), but the idle/before-sleep lock failed.

Switching the locker program would NOT have fixed this — any PAM locker
spawned under `no_new_privs` fails identically. The fix is the spawner.

## The deeper question: do we still need `idled` at all?

`idled` (packages/idled/, a bespoke Rust daemon) existed for exactly one
reason, per its own header: niri's Smithay-based `ext-idle-notify-v1`
didn't deliver **resumed** events (Smithay #1892), so a normal idle
daemon thought the user was permanently idle and locked while typing.
`idled` dodged this by reading `/dev/input/event*` directly.

Verified against the **pinned niri** (commit `38191826`, 2026-05-10) —
not a web search (which confabulated a "niri has no idle support"
answer):

- `src/handlers/mod.rs:517` — `impl IdleNotifierHandler` +
  `delegate_idle_notify!(State)` → ext-idle-notify-v1 implemented.
- `src/input/mod.rs:126` — `notify_activity()` is called on input
  events, which fires the **resumed** event (`niri.rs:6416`).

So the resumed-event bug — `idled`'s entire justification, and the
retirement condition written into idle.nix's header — is fixed. `idled`
is now pure liability: a custom daemon to maintain, and the source of
the lock bug. Retiring it **simplifies and fixes in one move.**

## What changed

- **`flake-modules/idle.nix`** rewritten to use home-manager's
  `services.swayidle` (no `NoNewPrivileges`, so swaylock authenticates):
  - timeouts: `lockAfter` → lock wrapper, `dpmsAfter` → niri
    power-off-monitors (+ resume power-on-monitors), `suspendAfter` →
    `systemctl suspend`.
  - events: `before-sleep` and `lock` → the lock wrapper.
  - `lock-screen` wrapper guards single-instance
    (`pidof -x swaylock || exec swaylock`) to kill the "another
    lockscreen is already running" noise from double-fires.
- **`flake-modules/niri.nix`** — `Super+Alt+L` now spawns
  `loginctl lock-session` (emits logind Lock → swayidle's `lock` event →
  one handler), instead of spawning swaylock directly. Manual and idle
  locks share one path.
- **PipeWire idle inhibit** — the `wayland-pipewire-idle-inhibit` bridge
  switched from `--idle-inhibitor d-bus` to `--idle-inhibitor wayland`.
  This replaces `idled`'s bespoke `org.freedesktop.ScreenSaver` D-Bus
  server: niri implements `IdleInhibitHandler`, so an active Wayland
  idle-inhibitor stops niri emitting idle → swayidle never fires. Chrome
  fullscreen video already speaks the Wayland protocol directly.
- **Battery → power-saver auto-switch** — `idled` bundled a UPower
  watcher that flipped power-profiles-daemon to "power-saver" below
  `powerSaverPercent`. Replaced with a tiny HM systemd **user timer +
  `writeShellApplication` script** (`battery-power-saver`) polling every
  60s, only emitted when `powerSaverPercent > 0` (laptops; desktops/VMs
  get nothing). Restores "balanced" above threshold+5% or while charging.
- **Deleted** `packages/idled/` and `overlays/idled.nix`; removed the
  overlay from `overlays/default.nix`. `packages/` is now empty.
- **Comments** across `battery.nix`, `power.nix`, `surface.nix`,
  `lockscreen.nix`, and the three host bridges updated from idled →
  swayidle.

## Vestigial `input` group

The `input` group on each login was added solely for `idled`'s raw
`/dev/input` access. niri + swaylock receive input via logind/libseat,
not this group, so it is now **unused**. Left in place (zero risk) but
flagged in the bridge comments as a safe future removal — dropping it
also removes a blanket keystroke-read (keylogger-grade) capability.

## Verification

- `nix build` green: pb-x1 (system + p HM), m-pc/pb-t480 toplevels
  (placeholder, `--impure`), and all kid HM configs (m@pb-t480,
  s@pb-t480, m@m-pc).
- Generated swayidle ExecStart confirmed: `-w timeout 300 <lock> timeout
  420 <dpms-off> resume <dpms-on> timeout 900 <suspend> before-sleep
  <lock> lock <lock>`.
- battery timer present on pb-x1 (powerSaverPercent=40), ABSENT on m-pc
  (=0). Bridge confirmed in `wayland` mode.
- `nix flake check --impure` — all checks passed (also formatted the
  m-pc hardware-configuration.nix that nixos-anywhere had emitted
  unformatted in the prior install commit).

## Apply / functional test

`sudo nixos-rebuild switch --flake .#pb-x1` then
`home-manager switch --flake .#'p@pb-x1'`. Then confirm:
1. Type continuously for ~30s past the old lock timeout — must NOT lock
   while typing (the resumed-event fix).
2. Lock via `Super+Alt+L` and via idle — password must unlock (the
   `NoNewPrivileges` fix).
3. Background audio (e.g. a song) holds off the idle lock.

## Follow-up audit (same session): idled feature parity + a bridge fix

Pulled idled's deleted source back from git and went module by module to
confirm nothing was silently dropped.

**Fully covered** by swayidle / the compositor / the pipewire bridge:
idle detection, staged lock→dpms→suspend, DPMS resume, lock-before-sleep
(swaylock daemonizes *after* acquiring the lock, so it replaces idled's
`lock_settle_ms` hack), no-re-lock-from-elapsed-time, lid/power-key not
counted as activity, input hotplug, and audio/video-keeps-awake.

**Behavioral difference — battery power-saver:** idled was event-driven
(UPower signal) and restored the *previously active* profile; the new
timer polls every 60s and restores to `balanced` specifically. So up to
60s latency, and a host normally on `performance` would be left on
`balanced` after a low-battery dip. Accepted.

**Genuine gaps (accepted, not closed):**
- `org.freedesktop.ScreenSaver` D-Bus server is gone. Apps that inhibit
  idle *only* via that API **and** produce no audio (silent slideshow,
  some e-readers/Electron) won't hold off the lock. Everything with
  audio is covered by the pipewire→wayland bridge; browsers/mpv use the
  native wayland idle-inhibit protocol. Operator chose to leave it.
- logind idle inhibitors (`systemd-inhibit --what=idle`) are no longer
  honored — niri/swayidle respect the wayland idle-inhibit protocol, not
  logind `BlockInhibited`. Niche; accepted.

**Regression found & fixed:** the `wayland-pipewire-idle-inhibit` unit
was sitting `failed` on the live system. `--idle-inhibitor wayland`
newly needs `WAYLAND_DISPLAY`; the unit started before the compositor
env was imported, failed fast 6× and tripped the start-limit into a
stranded `failed` state. Fixed by adding
`ConditionEnvironment = "WAYLAND_DISPLAY"` (the same guard HM's swayidle
unit uses) so it waits cleanly instead of failing. Reset+restarted on
the live host (now active) and fixed in idle.nix for future boots.

## Follow-up: tighten the battery power-saver to match idled

The first replacement was a stateless poller, which differed from idled
in two ways. Tightened by adding a per-session snapshot file
($XDG_RUNTIME_DIR/battery-power-saver.snapshot, the file analogue of
idled's in-memory snapshot):
- Restores the **previously-active** profile (e.g. performance), not a
  hardcoded "balanced".
- Acts once on descent; while the snapshot exists it never re-touches
  the profile, so a manual override below the threshold sticks.
Recovery still only restores if still on power-saver (never overrides a
manual change). Verified with a mocked state-machine test. Remaining
difference vs idled: 60s poll latency instead of event-driven (accepted;
the operator kept the simple timer over a UPower watcher).
