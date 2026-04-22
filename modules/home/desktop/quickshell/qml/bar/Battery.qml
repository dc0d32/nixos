// Battery via /sys/class/power_supply. No-ops on desktops without a battery.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

RowLayout {
  id: root
  spacing: 4
  visible: root.present

  property bool   present: false
  property int    percent: 0
  property string status:  "Unknown"

  Process {
    id: poller
    command: ["sh", "-c",
      "for b in /sys/class/power_supply/BAT*; do " +
      "  [ -d \"$b\" ] || continue; " +
      "  printf '%s\\n%s\\n' \"$(cat $b/capacity 2>/dev/null)\" \"$(cat $b/status 2>/dev/null)\"; " +
      "  exit 0; " +
      "done"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        const lines = text.trim().split("\n")
        if (lines.length >= 2 && lines[0] !== "") {
          root.present = true
          root.percent = parseInt(lines[0]) || 0
          root.status  = lines[1]
        } else {
          root.present = false
        }
      }
    }
  }

  Timer { interval: 10000; running: true; repeat: true; onTriggered: poller.running = true }

  Text {
    font.family: Theme.iconFont
    font.pixelSize: 16
    color: root.percent <= 15 ? Theme.red
         : root.status === "Charging" ? Theme.green
         : Theme.yellow
    text: root.status === "Charging"
      ? "battery_charging_full"
      : root.percent > 80 ? "battery_full"
      : root.percent > 50 ? "battery_5_bar"
      : root.percent > 20 ? "battery_3_bar"
                          : "battery_1_bar"
  }
  Text {
    font.family: Theme.font
    font.pixelSize: 12
    color: Theme.subtext
    text: root.percent + "%"
  }
}
