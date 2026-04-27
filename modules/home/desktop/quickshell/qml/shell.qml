import Quickshell
import Quickshell.Io
import QtQuick

import "bar"
import "osd"
import "media"
import "notifications"
import "lock"

Scope {
  Variants {
    model: Quickshell.screens
    Bar {
      required property var modelData
      screen: modelData
    }
  }

  VolumeOsd { }
  MediaOsd { }
  NotificationCenter { }
  LockScreen { id: lock }

  // Flyout panels (one set; they pick their screen via anchors)
  FlyoutBackdrop { }
  NetworkFlyout { }
  VolumeFlyout { }
  BatteryFlyout { }
  WeatherFlyout { }
  BrightnessFlyout { }
  ClockFlyout { }
  MediaFlyout { }

  IpcHandler {
    target: "launcher"
    function toggle() { }
  }
  IpcHandler {
    target: "lock"
    function lock() { lock.lock(); }
  }
}
