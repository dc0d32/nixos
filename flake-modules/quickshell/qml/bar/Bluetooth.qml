// Bluetooth status chip. State from BluetoothState (event-driven via
// `bluetoothctl --monitor`); this file is pure rendering + click handling.
//
// Icon set:
//   bluetooth_disabled — controller off
//   bluetooth          — on, nothing connected
//   bluetooth_connected— on, ≥1 device connected
//   bluetooth_searching— on, scan in progress (overrides connected)
//
// Label: connected device name if exactly one is connected; "N devices"
// if more than one; "off" if controller down; otherwise empty so the
// chip stays icon-only.
import Quickshell
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight

  property bool tooltipShown: false

  // Surfaces consumed by Bar.qml's tooltip binding.
  readonly property bool   powered:        BluetoothState.powered
  readonly property int    connectedCount: BluetoothState.connectedCount
  readonly property string label: {
    if (!BluetoothState.powered) return "off"
    if (BluetoothState.connectedCount === 0) return ""
    if (BluetoothState.connectedCount === 1) {
      for (const d of BluetoothState.pairedList) if (d.connected) return d.name
      return ""
    }
    return BluetoothState.connectedCount + " devices"
  }

  readonly property string iconName:
    !BluetoothState.powered      ? "bluetooth_disabled"
    : BluetoothState.discovering ? "bluetooth_searching"
    : connectedCount > 0         ? "bluetooth_connected"
                                 : "bluetooth"

  readonly property color iconColor:
    !BluetoothState.powered      ? Theme.muted
    : BluetoothState.discovering ? Theme.accent
    : connectedCount > 0         ? Theme.sky
                                 : Theme.subtext

  RowLayout {
    id: row; anchors.centerIn: parent; spacing: 4
    Text { font.family: Theme.iconFont; font.pixelSize: 16
           color: root.iconColor; text: root.iconName }
    Text { font.family: Theme.font; font.pixelSize: 12; color: Theme.subtext
           text: root.label; elide: Text.ElideRight
           Layout.preferredWidth: root.label === "" ? 0 : 60
           visible: root.label !== "" }
  }

  MouseArea {
    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
    onClicked: FlyoutManager.toggle("bluetooth")
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); root.tooltipShown = false }
    Timer { id: tipTimer; interval: 600; onTriggered: root.tooltipShown = true }
  }
}
