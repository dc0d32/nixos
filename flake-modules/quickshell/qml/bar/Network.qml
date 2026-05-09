// Network status chip. State from NetworkState (event-driven via
// `nmcli monitor`); this file is pure rendering + click handling.
//
// Click launches `alacritty -e nmtui`. The previous implementation
// opened an inline AP-list flyout with a password sub-row, but the
// password TextInput could not receive keystrokes — the bar's
// layer-shell surface defaults to WlrKeyboardFocus.None and no amount
// of QML focus juggling fixes that without granting the bar
// keyboard-focus rights, which has its own side effects. nmtui is the
// least-surprising answer: it's already on the system as part of the
// NetworkManager package and handles the full picker + auth flow in
// a real terminal that niri focuses normally.
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
    // execDetached: the spawned alacritty is fully detached, so quickshell
    // doesn't track it and won't get blocked if nmtui takes a long time
    // (e.g. user leaves the picker open). NetworkManager picks up the new
    // connection via D-Bus; NetworkState's `nmcli monitor` keeps the chip
    // label in sync without any explicit refresh from this side.
    onClicked: Quickshell.execDetached(["alacritty", "-e", "nmtui"])
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); root.tooltipShown = false }
    Timer { id: tipTimer; interval: 600; onTriggered: root.tooltipShown = true }
  }
}
