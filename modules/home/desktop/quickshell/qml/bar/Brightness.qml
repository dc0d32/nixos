// Brightness widget. Scroll to adjust. Click to open flyout.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight

  property int brightness:    0
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

  Timer { interval: 50; running: true; repeat: true; onTriggered: { maxPoller.running = true; poller.running = true } }

  RowLayout {
    id: row
    anchors.centerIn: parent
    spacing: 4

    Text {
      font.family: Theme.iconFont
      font.pixelSize: 14
      color: Theme.yellow
      text: "brightness_high"
    }
    Text {
      font.family: Theme.font
      font.pixelSize: 11
      color: Theme.subtext
      text: root.brightness + "%"
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton
    onClicked: FlyoutManager.toggle("brightness")
    onWheel: {
      const delta = wheel.angleDelta.y > 0 ? "+5%" : "5%-"
      Quickshell.execDetached(["brightnessctl", "set", delta])
      wheel.accepted = true
    }
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); tip.shown = false }

    Timer { id: tipTimer; interval: 600; onTriggered: tip.shown = true }

    BarTooltip {
      id: tip
      text: "Brightness: " + root.brightness + "%"
    }
  }
}
