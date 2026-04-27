// Battery flyout: percent, status, estimated time remaining.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import "../.."

Item {
  id: root
  property real chipCenterX: 0
  property real chipWidth:   0

  readonly property int cardWidth: 200
  readonly property int istmusW:   Math.max(chipWidth, 24)

  visible: FlyoutManager.active === "battery"

  x: Math.min(Math.max(Math.round(chipCenterX - cardWidth / 2), 0),
              (parent ? parent.width - cardWidth : 0))
  y: Theme.barHeight
  width:  cardWidth
  height: Theme.gap + col.implicitHeight + 20

  property int    percent:  0
  property string status:   "Unknown"
  property string timeLeft: ""

  onVisibleChanged: { if (visible) poller.running = true }

  Process {
    id: poller
    command: ["sh", "-c",
      "for b in /sys/class/power_supply/BAT*; do [ -d \"$b\" ] || continue; " +
      "cap=$(cat $b/capacity 2>/dev/null); st=$(cat $b/status 2>/dev/null); " +
      "tte=$(cat $b/time_to_empty_now 2>/dev/null || echo ''); " +
      "ttf=$(cat $b/time_to_full_now 2>/dev/null || echo ''); " +
      "printf '%s\\n%s\\n%s\\n%s\\n' \"$cap\" \"$st\" \"$tte\" \"$ttf\"; exit 0; done"]
    running: false
    stdout: StdioCollector { onStreamFinished: {
      const lines = text.trim().split("\n"); if (lines.length < 2) return
      root.percent = parseInt(lines[0]) || 0; root.status = lines[1] || "Unknown"
      const secs = parseInt(root.status === "Charging" ? lines[3] : lines[2]) || 0
      if (secs > 0) {
        const totalMin = secs > 10000 ? Math.round(secs / 60) : secs
        const h = Math.floor(totalMin / 60), m = totalMin % 60
        root.timeLeft = h > 0 ? h + "h " + m + "m" : m + "m"
      } else root.timeLeft = ""
    }}
  }
  Timer { interval: 10000; running: root.visible; repeat: true; onTriggered: poller.running = true }

  // isthmus
  Rectangle {
    x: Math.round((root.cardWidth - root.istmusW) / 2); y: 0
    width: root.istmusW; height: Theme.gap + Theme.radius
    color: Theme.base; topLeftRadius: Theme.radius / 2; topRightRadius: Theme.radius / 2
    bottomLeftRadius: 0; bottomRightRadius: 0
  }

  // card
  Rectangle {
    x: 0; y: Theme.gap; width: root.cardWidth
    implicitHeight: col.implicitHeight + 20
    radius: Theme.radius; color: Theme.base; opacity: Theme.opacity
    border.color: Theme.surface1; border.width: 1

    Column {
      id: col
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 14; anchors.topMargin: 14
      spacing: 10

      RowLayout {
        width: parent.width; spacing: 8
        Text { font.family: Theme.iconFont; font.pixelSize: 24
               color: root.percent <= 15 ? Theme.red : root.status === "Charging" ? Theme.green : Theme.yellow
               text: root.status === "Charging" ? "battery_charging_full"
                   : root.percent > 80 ? "battery_full" : root.percent > 50 ? "battery_5_bar"
                   : root.percent > 20 ? "battery_3_bar" : "battery_1_bar" }
        Column { spacing: 2
          Text { font.family: Theme.font; font.pixelSize: 20; font.bold: true; color: Theme.text; text: root.percent + "%" }
          Text { font.family: Theme.font; font.pixelSize: 11
                 color: root.status === "Charging" ? Theme.green : root.percent <= 15 ? Theme.red : Theme.subtext
                 text: root.status } }
      }

      Rectangle { width: parent.width; height: 6; radius: 3; color: Theme.surface1
        Rectangle { width: parent.width * (root.percent / 100.0); height: parent.height; radius: 3
                    color: root.percent <= 15 ? Theme.red : root.status === "Charging" ? Theme.green : Theme.yellow
                    Behavior on width { NumberAnimation { duration: 300 } } }
      }

      Text { visible: root.timeLeft !== ""; font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
             text: root.status === "Charging" ? "Full in ~" + root.timeLeft : "~" + root.timeLeft + " remaining" }
    }
  }
}
