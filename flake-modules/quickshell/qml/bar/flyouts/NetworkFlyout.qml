// Network flyout: current connection + AP list with connect/password flow.
// Connection state and AP list come from NetworkState (event-driven via
// `nmcli monitor`); this file owns only the inline password UX.
import Quickshell
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

import "../.."

Item {
  id: root
  property real chipCenterX: 0
  property real chipWidth:   0

  readonly property int cardWidth:  280
  readonly property int istmusH:    Theme.gap
  readonly property int istmusW:    Math.max(chipWidth, 24)

  visible: FlyoutManager.active === "network"

  // Position below bar strip, centered on chip
  x: Math.min(Math.max(Math.round(chipCenterX - cardWidth / 2), 0),
              (parent ? parent.width - cardWidth : 0))
  y: Theme.barHeight
  width:  cardWidth
  height: istmusH + col.implicitHeight + 20

  // ── inline UX state (password prompt) ───────────────────────────────
  property string pendingSsid:   ""
  property bool   showPassField: false
  property string connectError:  ""

  // Refresh once when the flyout opens; nmcli monitor handles updates
  // afterwards. The check timer notices auth failures (no state change
  // event arrives if NM rejects the password silently).
  onVisibleChanged: {
    if (visible) {
      NetworkState.refreshStatus()
      NetworkState.refreshAps()
    }
  }

  function tryConnect(ssid) {
    pendingSsid = ssid; showPassField = false; connectError = ""
    NetworkState.tryConnect(ssid)
    checkTimer.restart()
  }
  function connectWithPassword(ssid, pwd) {
    connectError = ""
    NetworkState.connectWithPassword(ssid, pwd)
    checkTimer.restart()
  }

  Timer { id: checkTimer; interval: 2500; repeat: false
          onTriggered: {
            if (root.pendingSsid !== "" && NetworkState.currentSsid !== root.pendingSsid) {
              root.showPassField = true; root.connectError = "Authentication failed"
            } else {
              root.pendingSsid = ""; root.showPassField = false; root.connectError = ""
            }
          } }

  // ── isthmus ─────────────────────────────────────────────────────────
  Isthmus {
    cardWidth: root.cardWidth
    neckWidth: root.istmusW
    fillColor: Theme.base
  }

  // ── card ─────────────────────────────────────────────────────────────
  Rectangle {
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

      RowLayout {
        width: parent.width; spacing: 6
        Text { font.family: Theme.iconFont; font.pixelSize: 18
               color: NetworkState.currentState === "off" ? Theme.muted : Theme.sky
               text: NetworkState.currentState === "wifi"  ? "wifi"
                   : NetworkState.currentState === "wired" ? "lan"
                                                           : "wifi_off" }
        Text { Layout.fillWidth: true; font.family: Theme.font; font.pixelSize: 13; font.bold: true
               color: Theme.text
               text: NetworkState.currentSsid !== "" ? NetworkState.currentSsid : "Not connected"
               elide: Text.ElideRight }
        Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
               text: NetworkState.currentState }
      }

      Rectangle { width: parent.width; height: 1; color: Theme.surface1 }

      Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
             text: NetworkState.apList.length === 0 ? "Scanning…" : "Available networks" }

      ListView {
        width: parent.width; height: Math.min(contentHeight, 220); clip: true
        model: NetworkState.apList; spacing: 2
        delegate: Column {
          required property var modelData
          width: ListView.view.width

          Rectangle {
            id: apRow; width: parent.width; height: 32; radius: 6
            color: apHover.containsMouse ? Theme.surface0 : "transparent"
            RowLayout {
              anchors.fill: parent; anchors.leftMargin: 4; anchors.rightMargin: 6; spacing: 4
              Text { font.family: Theme.iconFont; font.pixelSize: 14
                     color: modelData.inUse ? Theme.sky : Theme.muted
                     text: modelData.inUse ? "wifi" : (modelData.secured ? "lock" : "wifi") }
              Text { Layout.fillWidth: true; font.family: Theme.font; font.pixelSize: 12
                     color: modelData.inUse ? Theme.text : Theme.subtext
                     text: modelData.ssid; elide: Text.ElideRight }
              Rectangle {
                width: 32; height: 14; radius: 7
                color: modelData.signal >= 70 ? Theme.green : modelData.signal >= 40 ? Theme.yellow : Theme.red
                opacity: 0.2
                Text { anchors.centerIn: parent; font.family: Theme.font; font.pixelSize: 9; font.bold: true
                       color: modelData.signal >= 70 ? Theme.green : modelData.signal >= 40 ? Theme.yellow : Theme.red
                       text: modelData.signal + "%" }
              }
              Text { font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.accent; text: "sync"
                     visible: root.pendingSsid === modelData.ssid && !root.showPassField
                     RotationAnimator on rotation { running: parent.visible; from: 0; to: 360; duration: 1000; loops: Animation.Infinite } }
            }
            MouseArea { id: apHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { if (!modelData.inUse) root.tryConnect(modelData.ssid) } }
          }

          // Password sub-row
          Column {
            visible: root.pendingSsid === modelData.ssid && root.showPassField
            width: parent.width; spacing: 4; topPadding: 4
            Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.urgent; leftPadding: 8
                   text: root.connectError !== "" ? root.connectError : "Password required" }
            RowLayout {
              width: parent.width; spacing: 4
              Rectangle { Layout.fillWidth: true; height: 28; radius: 6; color: Theme.surface0; border.color: Theme.surface2; border.width: 1
                TextInput { id: passInput; anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                            anchors.leftMargin: 8; anchors.rightMargin: 8
                            font.family: Theme.font; font.pixelSize: 12; color: Theme.text; echoMode: TextInput.Password
                            focus: root.showPassField && root.pendingSsid === modelData.ssid
                            Keys.onReturnPressed: root.connectWithPassword(modelData.ssid, passInput.text) } }
              Rectangle { width: 60; height: 28; radius: 6; color: Theme.accent
                Text { anchors.centerIn: parent; font.family: Theme.font; font.pixelSize: 12; font.bold: true; color: Theme.base; text: "Connect" }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: root.connectWithPassword(modelData.ssid, passInput.text) } }
            }
          }
        }
      }

      Rectangle { width: parent.width; height: 1; color: Theme.surface1
                  visible: NetworkState.currentState !== "off" && NetworkState.currentState !== "unknown" }

      Rectangle { width: parent.width; height: 30; radius: 6
                  visible: NetworkState.currentState !== "off" && NetworkState.currentState !== "unknown"
                  color: disconnHover.containsMouse ? Theme.surface0 : "transparent"
        RowLayout { anchors.fill: parent; anchors.leftMargin: 6; spacing: 4
          Text { font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.urgent; text: "wifi_off" }
          Text { font.family: Theme.font; font.pixelSize: 12; color: Theme.urgent; text: "Disconnect" } }
        MouseArea { id: disconnHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: { NetworkState.disconnect(); FlyoutManager.close() } }
      }

      Item { height: 2 }
    }
  }
}
