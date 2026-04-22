// Top-level quickshell entry point. Composes the bar, notifications, launcher,
// lock, media OSD, and volume/brightness OSD into a single shell.
import Quickshell
import QtQuick

import "bar"
import "notifications"
import "launcher"
import "lock"
import "media"
import "osd"

Scope {
  // Per-screen bar. Variants spawns one PanelWindow per connected screen.
  Variants {
    model: Quickshell.screens
    Bar {
      required property var modelData
      screen: modelData
    }
  }

  // Singletons — one instance each, not per-screen.
  NotificationCenter { }
  Launcher          { id: launcher }
  LockScreen        { id: lock }
  MediaOsd          { }
  VolumeOsd         { }

  // Expose IPC handles so niri keybinds (or anything) can trigger them:
  //   quickshellipc call launcher toggle
  //   quickshellipc call lock lock
  IpcHandler {
    target: "launcher"
    function toggle() { launcher.toggle() }
  }
  IpcHandler {
    target: "lock"
    function lock() { lock.lock() }
  }
}
