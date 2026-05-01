import Quickshell
import Quickshell.Io
import QtQuick

import "bar"
import "osd"
import "media"
import "notifications"
import "lock"
import "launcher"
import "clipboard"
import "screenshot"

Scope {
  VolumeOsd { }
  BrightnessOsd { }
  MediaOsd { }
  NotificationCenter { id: notifCenter }
  LockScreen { id: lockScreen }
  AppLauncher { }
  ClipboardHistory { }
  ScreenshotPicker { }

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
