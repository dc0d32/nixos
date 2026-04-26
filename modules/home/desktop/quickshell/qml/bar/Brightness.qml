import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

RowLayout {
  id: root
  spacing: 4

  property int brightness: 0
  property int maxBrightness: 100

  Process {
    id: maxPoller
    command: ["brightnessctl", "max"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        const val = parseInt(text.trim())
        if (!isNaN(val) && val > 0) root.maxBrightness = val
      }
    }
  }

  Process {
    id: poller
    command: ["brightnessctl", "get"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        const val = parseInt(text.trim())
        if (!isNaN(val)) root.brightness = Math.round((val / root.maxBrightness) * 100)
      }
    }
  }

  Timer { interval: 50; running: true; repeat: true; onTriggered: { maxPoller.running = true; poller.running = true; } }

  Text {
    font.family: Theme.iconFont
    font.pixelSize: 16
    color: Theme.yellow
    text: "brightness_high"
  }

  Text {
    font.family: Theme.font
    font.pixelSize: 12
    color: Theme.subtext
    text: root.brightness + "%"
    Layout.preferredWidth: 40
  }

  MouseArea {
    Layout.preferredWidth: 10
    Layout.fillHeight: true
    acceptedButtons: Qt.NoButton
    onWheel: {
      const delta = wheel.angleDelta.y > 0 ? "+5%" : "5%-"
      Quickshell.execDetached(["brightnessctl", "set", delta])
      wheel.accepted = true
    }
  }
}