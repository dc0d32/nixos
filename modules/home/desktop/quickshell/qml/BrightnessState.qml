// Singleton: backlight percent + max value, refreshed by long-running
// `udevadm monitor` on the backlight subsystem (event-driven). Replaces
// the previous flyout-side 200ms polling Timer and consolidates the
// brightnessctl reads previously duplicated in Brightness.qml and
// BrightnessFlyout.qml.
//
// Surface:
//   percent : int  — 0..100
//   max     : int  — raw kernel max-brightness (positive integer)
pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick

QtObject {
  id: root

  property int percent: 0
  property int max:     100

  function refresh() { getter.running = true }

  property Process _maxGetter: Process {
    command: ["brightnessctl", "max"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        const v = parseInt(text.trim())
        if (!isNaN(v) && v > 0) root.max = v
      }
    }
  }

  property Process _getter: Process {
    id: getter
    command: ["brightnessctl", "get"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        const v = parseInt(text.trim())
        if (!isNaN(v)) root.percent = Math.round((v / root.max) * 100)
      }
    }
  }

  // Long-running udev monitor on the backlight subsystem. Each "change"
  // line in /sys/class/backlight triggers a re-read. No polling.
  property Process _udevMon: Process {
    command: ["udevadm", "monitor", "--udev", "--subsystem-match=backlight"]
    running: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: data => {
        if (data && data.indexOf(" change ") !== -1) root.refresh()
      }
    }
  }
}
