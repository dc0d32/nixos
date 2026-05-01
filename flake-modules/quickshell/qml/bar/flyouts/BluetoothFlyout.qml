// Bluetooth flyout: controller toggle + paired-device list with
// connect/disconnect/forget, plus scan toggle and discovered-device
// list with pair flow (PIN/passkey overlay when required). State and
// commands come from BluetoothState (event-driven via
// `bluetoothctl --monitor`); this file owns only the inline UX.
//
// Layout:
//   [bluetooth icon] On Bluetooth          [scan ⌒]
//   ───────────────────────────────────────
//   Paired
//     [icon] Sony WH-1000XM4   [83%]   [✓ connected]
//     [icon] Logitech MX Master       [connect]
//   ───────────────────────────────────────
//   Available (during scan)
//     [icon] Galaxy Buds Pro          [pair]
//   ───────────────────────────────────────
//   [PIN entry overlay when pinPromptMac !== ""]
//   ───────────────────────────────────────
//   [bluetooth_off] Turn off Bluetooth
import Quickshell
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

import "../.."

Item {
  id: root
  property real chipCenterX: 0
  property real chipWidth:   0

  readonly property int cardWidth:  300
  readonly property int istmusH:    Theme.gap
  readonly property int istmusW:    Math.max(chipWidth, 24)

  visible: FlyoutManager.active === "bluetooth"

  x: Math.min(Math.max(Math.round(chipCenterX - cardWidth / 2), 0),
              (parent ? parent.width - cardWidth : 0))
  y: Theme.barHeight
  width:  cardWidth
  height: istmusH + card.implicitHeight + 20

  // Refresh once on open; --monitor handles updates afterwards. Also
  // start a scan automatically so the discovered list populates without
  // an extra click — stop it when the flyout closes to save power.
  onVisibleChanged: {
    if (visible) {
      BluetoothState.refreshAll()
      if (BluetoothState.powered) BluetoothState.startScan()
    } else {
      if (BluetoothState.discovering) BluetoothState.stopScan()
    }
  }

  // Split pairedList for the two sub-lists.
  readonly property var pairedDevices:
    BluetoothState.pairedList.filter(d => d.paired)
  readonly property var discoveredDevices:
    BluetoothState.pairedList.filter(d => !d.paired)

  // Map BlueZ Icon strings to Material Symbols glyphs.
  function deviceIcon(icon) {
    if (!icon) return "bluetooth"
    if (icon.indexOf("audio")    >= 0) return "headphones"
    if (icon.indexOf("headset")  >= 0) return "headset_mic"
    if (icon.indexOf("phone")    >= 0) return "smartphone"
    if (icon.indexOf("computer") >= 0) return "computer"
    if (icon.indexOf("input-keyboard") >= 0) return "keyboard"
    if (icon.indexOf("input-mouse") >= 0) return "mouse"
    if (icon.indexOf("input-gaming") >= 0) return "sports_esports"
    if (icon.indexOf("input")    >= 0) return "keyboard"
    if (icon.indexOf("watch")    >= 0) return "watch"
    if (icon.indexOf("printer")  >= 0) return "print"
    return "bluetooth"
  }

  // ── isthmus ─────────────────────────────────────────────────────────
  Isthmus {
    cardWidth: root.cardWidth
    neckWidth: root.istmusW
    fillColor: Theme.base
  }

  // ── card ────────────────────────────────────────────────────────────
  Rectangle {
    id: card
    x: 0; y: root.istmusH
    width: root.cardWidth
    implicitHeight: col.implicitHeight + 20
    radius: Theme.radius
    color: Theme.base
    opacity: Theme.opacity
    border.color: Theme.surface1; border.width: 1

    Column {
      id: col
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 8; anchors.topMargin: 10
      spacing: 6

      // ── Header: controller toggle + scan button ─────────────────
      RowLayout {
        width: parent.width; spacing: 6
        Text { font.family: Theme.iconFont; font.pixelSize: 18
               color: BluetoothState.powered ? Theme.sky : Theme.muted
               text: BluetoothState.powered ? "bluetooth" : "bluetooth_disabled" }
        Text { Layout.fillWidth: true; font.family: Theme.font; font.pixelSize: 13; font.bold: true
               color: Theme.text
               text: BluetoothState.powered ? "Bluetooth on" : "Bluetooth off" }

        // Scan toggle (only meaningful when powered).
        Rectangle {
          width: 28; height: 22; radius: 6
          visible: BluetoothState.powered
          color: scanHover.containsMouse ? Theme.surface1 : Theme.surface0
          border.color: BluetoothState.discovering ? Theme.accent : "transparent"
          border.width: 1
          Text {
            anchors.centerIn: parent; font.family: Theme.iconFont; font.pixelSize: 14
            color: BluetoothState.discovering ? Theme.accent : Theme.subtext
            text: "search"
            RotationAnimator on rotation {
              running: BluetoothState.discovering
              from: 0; to: 360; duration: 1500; loops: Animation.Infinite
            }
          }
          MouseArea {
            id: scanHover
            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: BluetoothState.discovering
                       ? BluetoothState.stopScan()
                       : BluetoothState.startScan()
          }
        }
      }

      Rectangle { width: parent.width; height: 1; color: Theme.surface1 }

      // ── Paired devices ─────────────────────────────────────────
      Text {
        font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
        text: root.pairedDevices.length === 0 ? "No paired devices" : "Paired"
        visible: BluetoothState.powered
      }

      ListView {
        width: parent.width
        height: Math.min(contentHeight, 180); clip: true
        model: root.pairedDevices; spacing: 2
        visible: BluetoothState.powered && root.pairedDevices.length > 0
        delegate: Rectangle {
          required property var modelData
          width: ListView.view.width; height: 32; radius: 6
          color: pHover.containsMouse ? Theme.surface0 : "transparent"
          RowLayout {
            anchors.fill: parent; anchors.leftMargin: 4; anchors.rightMargin: 6; spacing: 4
            Text { font.family: Theme.iconFont; font.pixelSize: 14
                   color: modelData.connected ? Theme.sky : Theme.muted
                   text: root.deviceIcon(modelData.icon) }
            Text { Layout.fillWidth: true; font.family: Theme.font; font.pixelSize: 12
                   color: modelData.connected ? Theme.text : Theme.subtext
                   text: modelData.name; elide: Text.ElideRight }
            // Battery pill (only if Battery1 reported a value).
            Rectangle {
              visible: modelData.battery >= 0
              width: 32; height: 14; radius: 7
              color: modelData.battery >= 50 ? Theme.green
                   : modelData.battery >= 20 ? Theme.yellow
                                             : Theme.red
              opacity: 0.2
              Text { anchors.centerIn: parent; font.family: Theme.font; font.pixelSize: 9; font.bold: true
                     color: modelData.battery >= 50 ? Theme.green
                          : modelData.battery >= 20 ? Theme.yellow
                                                    : Theme.red
                     text: modelData.battery + "%" }
            }
            // Action affordance: connect/disconnect.
            Text { font.family: Theme.iconFont; font.pixelSize: 14
                   color: modelData.connected ? Theme.sky : Theme.subtext
                   text: modelData.connected ? "link" : "link_off" }
          }
          MouseArea {
            id: pHover
            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
              if (mouse.button === Qt.RightButton) {
                BluetoothState.removeDevice(modelData.mac)
              } else if (modelData.connected) {
                BluetoothState.disconnectDevice(modelData.mac)
              } else {
                BluetoothState.connectDevice(modelData.mac)
              }
            }
          }
        }
      }

      // ── Discovered (during scan) ───────────────────────────────
      Rectangle { width: parent.width; height: 1; color: Theme.surface1
                  visible: BluetoothState.powered }

      Text {
        font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
        text: BluetoothState.discovering
              ? (root.discoveredDevices.length === 0 ? "Scanning…" : "Available")
              : "Tap ⌕ to scan for new devices"
        visible: BluetoothState.powered
      }

      ListView {
        width: parent.width
        height: Math.min(contentHeight, 140); clip: true
        model: root.discoveredDevices; spacing: 2
        visible: BluetoothState.powered && root.discoveredDevices.length > 0
        delegate: Rectangle {
          required property var modelData
          width: ListView.view.width; height: 32; radius: 6
          color: dHover.containsMouse ? Theme.surface0 : "transparent"
          RowLayout {
            anchors.fill: parent; anchors.leftMargin: 4; anchors.rightMargin: 6; spacing: 4
            Text { font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.muted
                   text: root.deviceIcon(modelData.icon) }
            Text { Layout.fillWidth: true; font.family: Theme.font; font.pixelSize: 12
                   color: Theme.subtext
                   text: modelData.name || modelData.mac; elide: Text.ElideRight }
            // Spinner if this MAC is mid-pair.
            Text { font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.accent
                   text: "sync"
                   visible: BluetoothState.pairingMac === modelData.mac
                            && BluetoothState.pinPromptMac === ""
                   RotationAnimator on rotation { running: parent.visible
                                                  from: 0; to: 360; duration: 1000
                                                  loops: Animation.Infinite } }
            Text { font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.subtext
                   text: "add_link"
                   visible: BluetoothState.pairingMac !== modelData.mac }
          }
          MouseArea {
            id: dHover
            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (BluetoothState.pairingMac === "") BluetoothState.pair(modelData.mac)
            }
          }
        }
      }

      // ── PIN/passkey entry overlay ──────────────────────────────
      Column {
        visible: BluetoothState.pinPromptMac !== ""
        width: parent.width; spacing: 4; topPadding: 4
        Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.accent; leftPadding: 4
               text: "Pairing: " + BluetoothState.pinPromptText }
        RowLayout {
          width: parent.width; spacing: 4
          Rectangle {
            Layout.fillWidth: true; height: 28; radius: 6
            color: Theme.surface0; border.color: Theme.surface2; border.width: 1
            TextInput {
              id: pinInput
              anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
              anchors.leftMargin: 8; anchors.rightMargin: 8
              font.family: Theme.font; font.pixelSize: 12; color: Theme.text
              focus: BluetoothState.pinPromptMac !== ""
              Keys.onReturnPressed: {
                BluetoothState.confirmPin(pinInput.text); pinInput.text = ""
              }
            }
          }
          Rectangle { width: 60; height: 28; radius: 6; color: Theme.accent
            Text { anchors.centerIn: parent; font.family: Theme.font; font.pixelSize: 12
                   font.bold: true; color: Theme.base; text: "OK" }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: { BluetoothState.confirmPin(pinInput.text); pinInput.text = "" } }
          }
          Rectangle { width: 60; height: 28; radius: 6; color: Theme.surface1
            Text { anchors.centerIn: parent; font.family: Theme.font; font.pixelSize: 12
                   color: Theme.urgent; text: "Cancel" }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: { BluetoothState.cancelPin(); pinInput.text = "" } }
          }
        }
      }

      // ── Last error (transient) ─────────────────────────────────
      Text {
        visible: BluetoothState.lastError !== ""
        width: parent.width; font.family: Theme.font; font.pixelSize: 11
        color: Theme.urgent; wrapMode: Text.Wrap
        text: BluetoothState.lastError
      }

      // ── Footer: power toggle ──────────────────────────────────
      Rectangle { width: parent.width; height: 1; color: Theme.surface1 }

      Rectangle {
        width: parent.width; height: 30; radius: 6
        color: powerHover.containsMouse ? Theme.surface0 : "transparent"
        RowLayout { anchors.fill: parent; anchors.leftMargin: 6; spacing: 4
          Text { font.family: Theme.iconFont; font.pixelSize: 14
                 color: BluetoothState.powered ? Theme.urgent : Theme.green
                 text: BluetoothState.powered ? "bluetooth_disabled" : "bluetooth" }
          Text { font.family: Theme.font; font.pixelSize: 12
                 color: BluetoothState.powered ? Theme.urgent : Theme.green
                 text: BluetoothState.powered ? "Turn off Bluetooth" : "Turn on Bluetooth" } }
        MouseArea {
          id: powerHover
          anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
          onClicked: BluetoothState.setPowered(!BluetoothState.powered)
        }
      }

      Item { height: 2 }
    }
  }
}
