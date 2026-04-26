// Network status via NetworkManager (nmcli). Shows an icon + SSID/wired label.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

RowLayout {
  id: root
  spacing: 4

  property string label: "…"
  property string state: "unknown"   // wifi | wired | off | unknown

  Process {
    id: poller
    command: ["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "device"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        let wifi = null, wired = null
        for (const line of text.split("\n")) {
          if (!line) continue
          const [type, st, conn] = line.split(":")
          if (st !== "connected") continue
          if (type === "wifi")     wifi  = conn
          if (type === "ethernet") wired = conn
        }
        if (wired) { root.state = "wired"; root.label = wired }
        else if (wifi) { root.state = "wifi"; root.label = wifi }
        else { root.state = "off"; root.label = "offline" }
      }
    }
  }

  Timer { interval: 5000; running: true; repeat: true; onTriggered: poller.running = true }

  Text {
    font.family: Theme.iconFont
    font.pixelSize: 16
    color: root.state === "off" ? Theme.muted : Theme.sky
    text: root.state === "wifi"  ? "wifi"
        : root.state === "wired" ? "lan"
        : "wifi_off"
  }
  Text {
    font.family: Theme.font
    font.pixelSize: 12
    color: Theme.subtext
    text: root.label
    elide: Text.ElideRight
    Layout.preferredWidth: 60
  }
}
