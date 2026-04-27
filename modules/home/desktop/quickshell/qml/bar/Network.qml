// Network status chip. Exposes tooltipShown for Bar.qml to drive BarTooltip.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight

  property string label:        "…"
  property string state:        "unknown"   // wifi | wired | off | unknown
  property bool   tooltipShown: false

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

  RowLayout {
    id: row; anchors.centerIn: parent; spacing: 4
    Text { font.family: Theme.iconFont; font.pixelSize: 16
           color: root.state === "off" ? Theme.muted : Theme.sky
           text: root.state === "wifi" ? "wifi" : root.state === "wired" ? "lan" : "wifi_off" }
    Text { font.family: Theme.font; font.pixelSize: 12; color: Theme.subtext
           text: root.label; elide: Text.ElideRight; Layout.preferredWidth: 60 }
  }

  MouseArea {
    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
    onClicked: FlyoutManager.toggle("network")
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); root.tooltipShown = false }
    Timer { id: tipTimer; interval: 600; onTriggered: root.tooltipShown = true }
  }
}
