# Session: quickshell as a waybar alternative — 2026-04-21

## Change

Added `modules/home/desktop/quickshell/` (directory module) so a host can opt
into [quickshell](https://quickshell.outfoxxed.me/) instead of waybar. Ships a
full-shell starter config in real QML files loaded from disk, not embedded in
nix strings.

## How to choose

In `hosts/<hostname>/variables.nix`:

```nix
desktop = {
  niri.enable = true;
  waybar.enable = true;       # default
  quickshell.enable = false;  # flip these to swap
};
```

Enable exactly one — turning both on draws two panels.

## Layout

```
modules/home/desktop/quickshell/
  default.nix                      # installs pkgs.quickshell, links qml/ into ~/.config/quickshell
  qml/
    shell.qml                      # entrypoint: composes Bar + NotificationCenter + Launcher + Lock + OSDs
    Theme.qml                      # singleton palette + geometry (Catppuccin Mocha-ish)
    qmldir                         # registers Theme as a singleton
    bar/
      Bar.qml                      # top panel
      Workspaces.qml               # niri workspaces (polls `niri msg --json workspaces`)
      Clock.qml
      SystemTray.qml
      Network.qml                  # nmcli
      Volume.qml                   # wpctl, scroll-to-adjust, middle-click mute
      Battery.qml                  # reads /sys/class/power_supply/BAT*
    notifications/NotificationCenter.qml   # org.freedesktop.Notifications popups (replaces mako)
    launcher/Launcher.qml          # fuzzy app launcher (replaces fuzzel), toggled via IPC
    lock/LockScreen.qml            # ext-session-lock-v1 session lock (PAM auth stub)
    media/MediaOsd.qml             # MPRIS now-playing popup
    osd/VolumeOsd.qml              # centered volume/brightness OSD, driven via IPC
```

## Why real QML files and not embedded strings

Quickshell's config language is QML. Dropping QML into `xdg.configFile.text`
loses editor highlighting, defeats hot reload, and makes diffs painful. Putting
`.qml` files under `modules/home/desktop/quickshell/qml/` and sourcing the
directory (`xdg.configFile."quickshell".source = ./qml`) keeps them as first
class files while still living inside this repo — consistent with the
"no separate dotfiles repo" rule (nix files generate what they can, raw QML
lives where QML belongs).

## IPC integration points

Two handles exposed in `shell.qml`, for binding niri keybinds or hotkeys to:

- `quickshellipc call launcher toggle` — open the app launcher.
- `quickshellipc call lock lock` — enter the lock screen.
- `quickshellipc call osd show "volume 42" 42` — show the centered OSD.

Wire volume/brightness key bindings so they *both* change the value AND call
the OSD, so the user gets visual feedback. Example for niri config:

```kdl
binds {
  Mod+Space       { spawn "quickshellipc" "call" "launcher" "toggle"; }
  Super+L         { spawn "quickshellipc" "call" "lock" "lock"; }
  XF86AudioRaiseVolume { spawn "sh" "-c" "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ && quickshellipc call osd show volume $(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{printf \"%d\", $2*100}')"; }
}
```

## Theming

`Theme.qml` is the single source of truth: palette (Catppuccin Mocha-ish),
radius, gaps, bar height, opacity, fonts. Retheme by editing that one file.
Uses `JetBrainsMono Nerd Font` for mono, `Inter` for UI, and
`Material Symbols Rounded` for icons (installed via `pkgs.material-symbols`).

## Design notes

- **Not baked into niri.** The module adds itself to
  `programs.niri.settings.spawn-at-startup` via `lib.mkAfter` so the autostart
  entry lives with the module that owns it, not in the niri module.
- **LockScreen is a stub for auth.** `ext-session-lock-v1` exposes the surface,
  but Quickshell does not do PAM itself. For real auth, hand off to `swaylock`
  from the enter-pressed handler, or implement a small PAM helper. The stub
  unlocks on Enter so the surface is testable.
- **Polling, not signals, for nmcli/wpctl/battery.** Cheap, avoids requiring
  D-Bus integrations; 1–10 s intervals depending on volatility.
- **Per-screen bars, singletons for overlays.** The bar is spawned per screen
  via `Variants { model: Quickshell.screens }`. Launcher, lock, media OSD,
  volume OSD are singletons pinned to the primary screen.

## Rationale

Waybar is a simpler default for a fresh machine, but quickshell is more
scriptable and flexible for ambitious niri setups. Keeping both behind feature
flags means a host can switch without cross-module surgery.

## Files touched / created

- `modules/home/desktop/quickshell/default.nix` (new)
- `modules/home/desktop/quickshell/qml/*` (new, 14 QML + qmldir files)
- `modules/home/default.nix` (import path changed to directory)
- `hosts/_template/variables.nix` (feature flag + comment)
- `README.md` (module list)

## Known TODOs

- Replace the LockScreen Enter-to-unlock stub with real PAM auth (swaylock
  handoff is simplest).
- Battery widget hides on desktops cleanly, but `visible: root.present` hides
  the whole layout; double-check the row contributes zero width when absent.
- The launcher's fuzzy match is a naive substring match. Swap for Levenshtein
  or a scoring function if it gets noisy.
- SystemTray icon `source: modelData.icon` relies on Quickshell 0.2+ tray API
  shape; if quickshell upstream changes the API, update `bar/SystemTray.qml`.
