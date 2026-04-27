// Brightness chip. Scroll adjusts, click opens flyout.
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

  Process { id: maxPoller; command: ["brightnessctl", "max"]; running: true
    stdout: StdioCollector { onStreamFinished: { const v = parseInt(text.trim()); if (!isNaN(v) && v > 0) root.maxBrightness = v } } }
  Process { id: poller; command: ["brightnessctl", "get"]; running: true
    stdout: StdioCollector { onStreamFinished: {
      const v = parseInt(text.trim())
      if (!isNaN(v)) root.brightness = Math.round((v / root.maxBrightness) * 100)
    }} }
  Timer { interval: 50; running: true; repeat: true; onTriggered: { maxPoller.running = true; poller.running = true } }

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
