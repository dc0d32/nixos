// Brightness chip. Initial value polled once; subsequent updates are pushed
// by a long-running `udevadm monitor` watching the backlight subsystem.
// Scroll adjusts, click opens flyout.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight

  property int  brightness:    0
  property int  maxBrightness: 100
  property bool tooltipShown:  false

  function _refresh() { getter.running = true }

  // One-shot reads on startup and after every udev event.
  Process {
    id: maxGetter
    command: ["brightnessctl", "max"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        const v = parseInt(text.trim())
        if (!isNaN(v) && v > 0) root.maxBrightness = v
      }
    }
  }
  Process {
    id: getter
    command: ["brightnessctl", "get"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        const v = parseInt(text.trim())
        if (!isNaN(v)) root.brightness = Math.round((v / root.maxBrightness) * 100)
      }
    }
  }

  // Long-running udev monitor for the backlight subsystem. Each event line
  // is a kernel notification that something in /sys/class/backlight changed;
  // we react by re-running `brightnessctl get`. Replaces the previous 50 ms
  // polling timer with a true event-driven flow.
  Process {
    id: udevMon
    command: ["udevadm", "monitor", "--udev", "--subsystem-match=backlight"]
    running: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: data => {
        // Lines from udevadm look like "UDEV  [..] change /devices/..."
        // — react on any "change" line. The header lines printed at startup
        // don't contain "change" so they're harmless.
        if (data.indexOf(" change ") !== -1) root._refresh()
      }
    }
  }

  RowLayout {
    id: row; anchors.centerIn: parent; spacing: 4
    Text { font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.yellow; text: "brightness_high" }
    Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.subtext; text: root.brightness + "%" }
  }

  MouseArea {
    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton
    onClicked: FlyoutManager.toggle("brightness")
    onWheel: {
      Quickshell.execDetached(["brightnessctl", "set", wheel.angleDelta.y > 0 ? "+5%" : "5%-"])
      wheel.accepted = true
    }
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); root.tooltipShown = false }
    Timer { id: tipTimer; interval: 600; onTriggered: root.tooltipShown = true }
  }
}
