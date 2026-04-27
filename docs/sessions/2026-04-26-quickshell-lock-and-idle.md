# Quickshell-based lock and idle (2026-04-26)

## Problem

The old sway-based idle system had bugs:
- `power-handler` in idle.nix ran swaylock in a loop, then suspend on ANY exit
- This caused suspend immediately after unlocking because the loop doesn't distinguish between power-key-triggered lock vs idle-triggered lock

## Solution

Implement lock, DPMS, and suspend directly in quickshell using:
1. **PAM authentication** via `Quickshell.Services.Pam.PamContext`
2. **Idle detection** via `Quickshell.Wayland.IdleMonitor` (requires ext-idle-notify-v1, which niri supports)

## Files changed

### New files
- `modules/home/desktop/quickshell/qml/lock/LockContext.qml` - PAM auth context
- `modules/home/desktop/quickshell/qml/pam/password.conf` - PAM config (just pam_unix)
- `modules/home/desktop/quickshell/qml/IdleController.qml` - idle detection

### Modified files
- `modules/home/desktop/quickshell/qml/lock/LockScreen.qml` - now uses PAM auth
- `modules/home/desktop/quickshell/qml/shell.qml` - wires in IdleController
- `modules/home/desktop/quickshell/qml/Theme.qml` - added `red` color
- `modules/nixos/desktop/quickshell.nix` - removed swaylock/swayidle
- `modules/home/desktop/idle.nix` - disabled when quickshell is enabled (still has power-handler for non-quickshell configs)

## Behavior

- 5 min idle → lock screen (quickshell lock with PAM)
- 7 min idle → DPMS off (via `niri msg action power-off-monitors`)
- 15 min idle → suspend (DPMS off + systemctl suspend)

The lock screen asks for your password and uses PAM to verify it. No more swaylock needed.

## Pam config

Uses `~/.config/quickshell/pam/password.conf` containing:
```
auth required pam_unix.so
```

This is simpler than the system login and doesn't include things like pam_fprintd that might not be configured.

## Notes

- PAM in quickshell requires the PAM module which is built into nixpkgs quickshell
- ext-idle-notify-v1 must be supported by compositor - niri supports it
- The idle monitors respect inhibitors (e.g., video playback)