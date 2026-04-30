# 2026-04-30 — Screen-lock inhibit for Chrome video and PipeWire streams

## Goal

`idled` was locking the screen during fullscreen YouTube in Chrome and
during background music in Spotify, because the only inhibitor source
it watched was logind's `BlockInhibited` (i.e. holders of
`systemd-inhibit --what=idle`). Modern Wayland media apps don't take
logind inhibitors — they call `org.freedesktop.ScreenSaver.Inhibit` on
the session bus, which on a niri+quickshell host has no listener.

Two coverage requirements:

1. **Chrome on fullscreen video** (uses ScreenSaver D-Bus directly).
2. **Any PipeWire output stream** (Spotify, mpv, podcasts) — even if
   the app itself doesn't speak ScreenSaver.

## Context

Pre-existing on this host:

- `idled` user daemon (introduced in `2026-04-29-idle-lock-fix.md`)
  with one inhibitor flag, set from logind `BlockInhibited` containing
  `idle`. Tick loop skips firing stages while the flag is true.
- niri compositor honors `idle-inhibit-unstable-v1` for clients but
  doesn't translate inhibits to anything `idled` can see.
- No GNOME / KDE / xfce4-screensaver running, so nothing was hosting
  `org.freedesktop.ScreenSaver` on the session bus. Chrome's
  fullscreen-video inhibit calls were silently failing into the void.

The decision tree:

| coverage source | option A | option B (chosen) |
|---|---|---|
| Chrome fullscreen video | extend idled with a Wayland idle-inhibit client (smithay-client-toolkit, ~80 LOC) | host `org.freedesktop.ScreenSaver` D-Bus server in idled |
| Spotify / mpv / any audio | poll PipeWire from a shell + `systemd-inhibit` wrapper | `wayland-pipewire-idle-inhibit --idle-inhibitor d-bus` against our hosted ScreenSaver |
| inhibitor flag aggregation | one shared flag, last writer wins | two flags (logind, screensaver) OR'd in the tick loop |

Hosting ScreenSaver covers Chrome **and** is the natural target the
PipeWire bridge already speaks (`--idle-inhibitor d-bus` mode). Single
ingress point, two producers (Chrome direct, bridge for everything else).

## Implementation

### `packages/idled/src/screensaver.rs` (new)

Hosts `org.freedesktop.ScreenSaver` on the session bus with the standard
five methods:

```
Inhibit(application_name: s, reason_for_inhibit: s) → cookie: u
UnInhibit(cookie: u) → ()
GetActive() → b              (always false; we don't expose lock state)
GetActiveTime() → u          (always 0)
SetActive(b) → b             (no-op, returns false)
```

Cookies are random non-zero u32s minted from a tiny PRNG (nanoseconds ⊕
atomic counter); collisions retry. `HashMap<cookie, Holder>` tracks
who's holding what for log purposes; the moment the map crosses
empty↔non-empty, the shared `Arc<Mutex<bool>>` flips.

The well-known name is requested via `zbus::ConnectionBuilder::session`.
The interface is registered at **two** object paths:

- `/org/freedesktop/ScreenSaver` — the canonical XDG path.
- `/ScreenSaver` — the legacy duplicate that Firefox, older mpv builds,
  and a few others hard-code.

If another screensaver service is already running we lose the bus-name
race; the task logs a warning and exits without taking the rest of
`idled` down. The logind inhibitor path keeps working.

### `packages/idled/src/main.rs` — two-source inhibitor

Previously: one `Arc<Mutex<bool>>` shared between `dbus::run` (the
logind watcher) and the tick loop. Adding a second writer would have
caused either to clobber the other on every state change.

New shape:

```rust
let logind_inhibitor      = Arc::new(Mutex::new(false));
let screensaver_inhibitor = Arc::new(Mutex::new(false));

// dbus::run gets logind_inhibitor.clone(), owns it exclusively.
// screensaver::run gets screensaver_inhibitor.clone(), owns it exclusively.

// Tick loop:
let inhibited = respect_inhib && (
    *logind_inhibitor.lock().await
    || *screensaver_inhibitor.lock().await
);
```

Each source is independent, no clobbering, additive coverage.

### `modules/home/desktop/idle.nix` — bridge service

```nix
systemd.user.services.wayland-pipewire-idle-inhibit = {
  Unit = {
    After = [ "graphical-session.target" "idled.service" ];
    PartOf = [ "graphical-session.target" ];
    Requires = [ "pipewire.service" ];
  };
  Service.ExecStart = ''
    ${pkgs.wayland-pipewire-idle-inhibit}/bin/wayland-pipewire-idle-inhibit \
      --idle-inhibitor d-bus --media-minimum-duration 5
  '';
  …
};
```

Key flag: `--idle-inhibitor d-bus`. The default `wayland` mode would
ask the compositor to register a Wayland inhibit object — which niri
honors but doesn't expose to `idled`. `d-bus` mode calls
`org.freedesktop.ScreenSaver.Inhibit` instead, hitting our own server.

`--media-minimum-duration 5` keeps short notification beeps from
triggering an inhibit; long enough to ignore blips, short enough to
catch a song starting.

Ordering note: `pipewire.service` is a **user** unit on this host (HM
+ rtkit-managed pipewire), so `Requires=` resolves cleanly in the
user manager.

## Verified

```sh
# Build idled with the new module (~30 deps fetched, then compile):
nix build --impure --expr '(builtins.getFlake (toString ./.)).nixosConfigurations.laptop.pkgs.idled'

# Build the home-manager generation including the new bridge service:
nix build --impure --expr '(builtins.getFlake (toString ./.)).homeConfigurations."p@laptop".activationPackage'
```

Both succeeded. Generated bridge unit verified to contain
`ExecStart=…/wayland-pipewire-idle-inhibit --idle-inhibitor d-bus
--media-minimum-duration 5`, `After=idled.service`,
`Requires=pipewire.service`.

After `home-manager switch`, user confirmed:

- Chrome fullscreen YouTube past `lockAfter=300` does not lock.
- Background Spotify past `lockAfter=300` does not lock.

Manual D-Bus probe:

```sh
busctl --user list | grep ScreenSaver
# → :1.NN  org.freedesktop.ScreenSaver  …  user@1000.service - …

busctl --user call org.freedesktop.ScreenSaver \
  /org/freedesktop/ScreenSaver \
  org.freedesktop.ScreenSaver Inhibit ss "test" "manual"
# → u 2154783729

journalctl --user -u idled -f
# → screensaver inhibit application=test reason=manual cookie=… total=1
# → screensaver inhibitor flag changed idle_inhibited=true
```

## Files

New:

- `packages/idled/src/screensaver.rs` (~210 LOC).

Modified:

- `packages/idled/src/main.rs` — `mod screensaver`, split inhibitor flag,
  spawn screensaver task.
- `modules/home/desktop/idle.nix` — install `wayland-pipewire-idle-
  inhibit` package and user service.
- `hosts/laptop/variables.nix` — drop stale "via stasis" comment.

## Open / future

- **Disconnect cleanup**: if a ScreenSaver client crashes without
  calling UnInhibit, its cookies leak forever. The XDG spec says the
  server should release them on `NameOwnerChanged` (peer disconnect).
  Not implemented yet — Chrome and the bridge both call UnInhibit
  cleanly on shutdown, and a stale inhibit only matters until the
  next idled restart. If a flaky client appears, add a sender-name
  watcher that GCs cookies whose owner unique-name vanished.
- **Bus-name race**: if a second screensaver provider ever shows up
  on this host (gnome-shell, ksmserver, etc.) we lose the well-known
  name and silently fall back to logind-only coverage. Worth a
  Prometheus metric or a periodic re-acquire attempt if this becomes
  a real failure mode. Today it's a non-issue.
- **PipeWire stream filtering**: `wayland-pipewire-idle-inhibit` has
  config-file rules to ignore specific sinks (e.g. don't inhibit on
  the HDMI sink while mirroring). Not used yet; default behavior
  inhibits on any output stream, which matches what the user wants.
- **Screensaver also for cosmic / KDE-style ScreenSaver clients**:
  the hosted interface is the standard one, so any future app that
  uses ScreenSaver will work out of the box.
