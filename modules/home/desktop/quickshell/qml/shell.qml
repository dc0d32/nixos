import Quickshell
import Quickshell.Io
import QtQuick

import "bar"
import "osd"
import "media"
import "notifications"
import "lock"

Scope {
  VolumeOsd { }
  MediaOsd { }
  NotificationCenter { id: notifCenter }
  LockScreen { id: lock }

  Variants {
    model: Quickshell.screens
    Bar {
      required property var modelData
      screen: modelData
      notificationServer: notifCenter.server
    }
  }

  IpcHandler {
    target: "launcher"
    function toggle() { }
  }
  IpcHandler {
    target: "lock"
    function lock() { lock.lock(); }
  }
}
