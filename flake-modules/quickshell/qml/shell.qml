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
  LockScreen { id: lockScreen }

  Variants {
    model: Quickshell.screens
    Bar {
      required property var modelData
      screen: modelData
      notificationServer: notifCenter.server
    }
  }

  IpcHandler {
    target: "lock"
    function lock() { lockScreen.lock(); }
  }
}
