// Network status chip. State from NetworkState (event-driven via
// `nmcli monitor`); this file is pure rendering + click handling.
import Quickshell
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight

  property bool tooltipShown: false

  readonly property string label:
    NetworkState.currentSsid !== "" ? NetworkState.currentSsid : "offline"

  RowLayout {
    id: row; anchors.centerIn: parent; spacing: 4
    Text { font.family: Theme.iconFont; font.pixelSize: 16
           color: NetworkState.currentState === "off" ? Theme.muted : Theme.sky
           text: NetworkState.currentState === "wifi"  ? "wifi"
               : NetworkState.currentState === "wired" ? "lan"
                                                       : "wifi_off" }
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
