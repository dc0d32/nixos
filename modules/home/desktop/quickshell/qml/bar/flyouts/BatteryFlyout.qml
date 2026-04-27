// Battery flyout: percent, status, estimated time remaining.
// Only shown when Battery.present (the bar widget already guards this,
// but FlyoutManager.toggle("battery") is only wired when battery is present).
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import "../.."

PanelWindow {
  id: root

  visible: FlyoutManager.active === "battery"
  color: "transparent"
  WlrLayershell.layer: WlrLayershell.Overlay
  WlrLayershell.namespace: "quickshell-flyout-battery"
  anchors { top: true; right: true }
  margins { top: Theme.barHeight + Theme.gap * 2; right: Theme.gap }
  implicitWidth: 200
  implicitHeight: card.implicitHeight

  property int    percent:   0
  property string status:    "Unknown"
  property string timeLeft:  ""

  Process {
    id: poller
    command: ["sh", "-c",
      "for b in /sys/class/power_supply/BAT*; do " +
      "  [ -d \"$b\" ] || continue; " +
      "  cap=$(cat $b/capacity 2>/dev/null); " +
      "  st=$(cat $b/status 2>/dev/null); " +
      "  tte=$(cat $b/time_to_empty_now 2>/dev/null || echo ''); " +
      "  ttf=$(cat $b/time_to_full_now 2>/dev/null || echo ''); " +
      "  printf '%s\\n%s\\n%s\\n%s\\n' \"$cap\" \"$st\" \"$tte\" \"$ttf\"; " +
      "  exit 0; " +
      "done"]
    running: root.visible
    stdout: StdioCollector {
      onStreamFinished: {
        const lines = text.trim().split("\n")
        if (lines.length < 2) return
        root.percent = parseInt(lines[0]) || 0
        root.status  = lines[1] || "Unknown"

        // time_to_empty_now / time_to_full_now are in seconds (some kernels) or minutes
        const tte = parseInt(lines[2]) || 0
        const ttf = parseInt(lines[3]) || 0
        const secs = (root.status === "Charging" ? ttf : tte)
        if (secs > 0) {
          // Values > 10000 are likely seconds, smaller likely minutes
          const totalMin = secs > 10000 ? Math.round(secs / 60) : secs
          const h = Math.floor(totalMin / 60)
          const m = totalMin % 60
          root.timeLeft = h > 0 ? h + "h " + m + "m" : m + "m"
        } else {
          root.timeLeft = ""
        }
      }
    }
  }

  Timer { interval: 10000; running: root.visible; repeat: true; onTriggered: poller.running = true }

  Rectangle {
    id: card
    anchors { top: parent.top; right: parent.right }
    width: 200
    implicitHeight: col.implicitHeight + 20
    radius: Theme.radius
    color: Theme.base
    opacity: Theme.opacity
    border.color: Theme.surface1; border.width: 1

    Column {
      id: col
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 14
      anchors.topMargin: 14
      spacing: 10

      // Icon + percent
      RowLayout {
        width: parent.width; spacing: 8
        Text {
          font.family: Theme.iconFont; font.pixelSize: 24
          color: root.percent <= 15 ? Theme.red
               : root.status === "Charging" ? Theme.green
               : Theme.yellow
          text: root.status === "Charging" ? "battery_charging_full"
              : root.percent > 80 ? "battery_full"
              : root.percent > 50 ? "battery_5_bar"
              : root.percent > 20 ? "battery_3_bar"
              : "battery_1_bar"
        }
        Column {
          spacing: 2
          Text {
            font.family: Theme.font; font.pixelSize: 20; font.bold: true
            color: Theme.text; text: root.percent + "%"
          }
          Text {
            font.family: Theme.font; font.pixelSize: 11
            color: root.status === "Charging" ? Theme.green
                 : root.percent <= 15 ? Theme.red
                 : Theme.subtext
            text: root.status
          }
        }
      }

      // Progress bar
      Rectangle {
        width: parent.width; height: 6; radius: 3; color: Theme.surface1
        Rectangle {
          width: parent.width * (root.percent / 100.0)
          height: parent.height; radius: 3
          color: root.percent <= 15 ? Theme.red
               : root.status === "Charging" ? Theme.green
               : Theme.yellow
          Behavior on width { NumberAnimation { duration: 300 } }
        }
      }

      // Time remaining
      Text {
        visible: root.timeLeft !== ""
        font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
        text: root.status === "Charging"
            ? "Full in ~" + root.timeLeft
            : "~" + root.timeLeft + " remaining"
      }
    }
  }
}
