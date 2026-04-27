# Session: quickshell idle via stasis — 2026-04-26

## Problem

Wanted idle detection for lock/DPMS/suspend without sway/i3 stuff.

## Solution

Use **[stasis](https://github.com/saltnpepper97/stasis)** - modern Wayland idle manager
with full Niri support. It's in nixpkgs.

### Setup

```
modules/home/desktop/idle.nix        # enables stasis package + config
modules/home/desktop/stasis/        # config.rune - idle timings & actions
modules/nixos/desktop/niri.nix   # adds stasis to system packages
modules/home/desktop/niri.nix       # removed swaylock hotkey, uses quickshell ipc
```

### How it works

- Lock via quickshell after 5 min idle: `quickshell ipc call lock lock`
- DPMS off via niri after 3 min: `niri msg action power-off-monitors`
- Suspend after 10 min idle

Stasis also inhibits idle when media apps (chromium, mpv, vlc) are playing.

### Why not quickshell IdleMonitor

Nixpkgs' quickshell 0.2.1 build doesn't include the `IdleMonitor` QML type
(requires `ext-idle-notify-v1` protocol compiled in).

### Key files

- `modules/home/desktop/idle.nix` - enables stasis, starts it via niri spawn-at-startup
- `modules/home/desktop/stasis/config.rune` - RUNE config for timeouts/actions
- `modules/home/desktop/quickshell/qml/lock/` - PAM-based lock screen

### Removed

- swaylock, swayidle - user explicitly requested NO sway stuff