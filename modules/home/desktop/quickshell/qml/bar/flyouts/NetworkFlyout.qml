// Network flyout: current connection + AP list with connect/password flow.
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

import "../.."

PanelWindow {
  id: root

  visible: FlyoutManager.active === "network"
  color: "transparent"
  WlrLayershell.layer: WlrLayershell.Overlay
  WlrLayershell.namespace: "quickshell-flyout-network"
  anchors { top: true; right: true }
  margins { top: Theme.barHeight + Theme.gap * 2; right: Theme.gap }
  implicitWidth: 280
  implicitHeight: card.implicitHeight

  // ── state ──────────────────────────────────────────────────────────────
  property string currentSsid:  ""
  property string currentState: "unknown"   // wifi | wired | off | unknown
  property string currentIface: ""

  // Selected AP for connect attempt
  property string pendingSsid:     ""
  property bool   pendingSecured:  false
  property bool   connecting:      false
  property bool   showPassField:   false
  property string connectError:    ""

  // AP list model: [{ssid, signal, secured, inUse}]
  property var apList: []

  // ── processes ──────────────────────────────────────────────────────────
  Process {
    id: statusPoller
    command: ["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION,DEVICE", "device"]
    running: root.visible
    stdout: StdioCollector {
      onStreamFinished: {
        root.currentSsid = ""
        root.currentIface = ""
        for (const line of text.split("\n")) {
          if (!line) continue
          const [type, st, conn, dev] = line.split(":")
          if (st !== "connected") continue
          if (type === "wifi") {
            root.currentSsid  = conn
            root.currentState = "wifi"
            root.currentIface = dev
            break
          }
          if (type === "ethernet") {
            root.currentSsid  = conn
            root.currentState = "wired"
            root.currentIface = dev
          }
        }
      }
    }
  }

  Process {
    id: apScanner
    command: ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list"]
    running: root.visible
    stdout: StdioCollector {
      onStreamFinished: {
        const seen = new Set()
        const list = []
        for (const line of text.split("\n")) {
          if (!line) continue
          // fields are colon-separated; IN-USE is '*' or ' '
          const idx = line.indexOf(":")
          if (idx < 0) continue
          const inUse   = line.substring(0, idx).trim() === "*"
          const rest    = line.substring(idx + 1)
          const parts   = rest.split(":")
          if (parts.length < 3) continue
          const ssid     = parts[0]
          const signal   = parseInt(parts[1]) || 0
          const security = parts.slice(2).join(":").trim()
          const secured  = security !== "" && security !== "--"
          if (!ssid || seen.has(ssid)) continue
          seen.add(ssid)
          list.push({ ssid, signal, secured, inUse })
        }
        list.sort((a, b) => b.signal - a.signal)
        root.apList = list
      }
    }
  }

  Process {
    id: connector
    command: ["true"]
    running: false
    stdout: StdioCollector { onStreamFinished: {} }
  }

  Process {
    id: disconnector
    command: ["true"]
    running: false
    stdout: StdioCollector { onStreamFinished: {} }
  }

  function tryConnect(ssid, secured) {
    root.pendingSsid    = ssid
    root.pendingSecured = secured
    root.showPassField  = false
    root.connectError   = ""
    root.connecting     = true
    connector.command   = ["nmcli", "device", "wifi", "connect", ssid]
    connector.running   = true
  }

  function connectWithPassword(ssid, pwd) {
    root.connecting    = true
    root.connectError  = ""
    connector.command  = ["nmcli", "device", "wifi", "connect", ssid, "password", pwd]
    connector.running  = true
  }

  function disconnect() {
    if (root.currentIface === "") return
    disconnector.command = ["nmcli", "device", "disconnect", root.currentIface]
    disconnector.running = true
    FlyoutManager.close()
  }

  // ── UI ────────────────────────────────────────────────────────────────
  Rectangle {
    id: card
    anchors { top: parent.top; right: parent.right }
    width: 280
    implicitHeight: col.implicitHeight + 16
    radius: Theme.radius
    color: Theme.base
    opacity: Theme.opacity
    border.color: Theme.surface1; border.width: 1

    Column {
      id: col
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 8
      anchors.topMargin: 10
      spacing: 6

      // ── current connection header ──
      RowLayout {
        width: parent.width
        spacing: 6
        Text {
          font.family: Theme.iconFont; font.pixelSize: 18
          color: root.currentState === "off" ? Theme.muted : Theme.sky
          text: root.currentState === "wifi"  ? "wifi"
              : root.currentState === "wired" ? "lan"
              : "wifi_off"
        }
        Text {
          Layout.fillWidth: true
          font.family: Theme.font; font.pixelSize: 13; font.bold: true
          color: Theme.text
          text: root.currentSsid !== "" ? root.currentSsid : "Not connected"
          elide: Text.ElideRight
        }
        Text {
          font.family: Theme.font; font.pixelSize: 11
          color: Theme.muted
          text: root.currentState
        }
      }

      Rectangle { width: parent.width; height: 1; color: Theme.surface1 }

      // ── AP list ──
      Text {
        font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
        text: root.apList.length === 0 ? "Scanning…" : "Available networks"
      }

      ListView {
        id: apListView
        width: parent.width
        height: Math.min(contentHeight, 240)
        clip: true
        model: root.apList
        spacing: 2

        delegate: Rectangle {
          id: apRow
          required property var modelData
          required property int index
          width: apListView.width
          height: 32
          radius: 6
          color: apRowHover.containsMouse ? Theme.surface0 : "transparent"

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 4; anchors.rightMargin: 6
            spacing: 4

            Text {
              font.family: Theme.iconFont; font.pixelSize: 14
              color: apRow.modelData.inUse ? Theme.sky : Theme.muted
              text: apRow.modelData.inUse ? "wifi" : (apRow.modelData.secured ? "lock" : "wifi")
            }

            Text {
              Layout.fillWidth: true
              font.family: Theme.font; font.pixelSize: 12
              color: apRow.modelData.inUse ? Theme.text : Theme.subtext
              text: apRow.modelData.ssid
              elide: Text.ElideRight
            }

            // Signal strength pill
            Rectangle {
              width: 32; height: 14; radius: 7
              color: apRow.modelData.signal >= 70 ? Theme.green
                   : apRow.modelData.signal >= 40 ? Theme.yellow
                   : Theme.red
              opacity: 0.25
              Rectangle {
                anchors.fill: parent; radius: parent.radius
                color: "transparent"
                Text {
                  anchors.centerIn: parent
                  font.family: Theme.font; font.pixelSize: 9; font.bold: true
                  color: apRow.modelData.signal >= 70 ? Theme.green
                       : apRow.modelData.signal >= 40 ? Theme.yellow
                       : Theme.red
                  text: apRow.modelData.signal + "%"
                }
              }
            }
          }

          // Password sub-row (shown when this AP is pending + showPassField)
          Column {
            anchors.top: parent.bottom
            anchors.left: parent.left; anchors.right: parent.right
            visible: root.pendingSsid === apRow.modelData.ssid && root.showPassField
            spacing: 4
            topPadding: 4

            Text {
              font.family: Theme.font; font.pixelSize: 11; color: Theme.urgent
              text: root.connectError !== "" ? root.connectError : "Password required"
              leftPadding: 8
            }

            RowLayout {
              width: parent.width
              spacing: 4

              Rectangle {
                Layout.fillWidth: true; height: 28
                radius: 6; color: Theme.surface0
                border.color: Theme.surface2; border.width: 1

                TextInput {
                  id: passInput
                  anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                  anchors.leftMargin: 8; anchors.rightMargin: 8
                  font.family: Theme.font; font.pixelSize: 12
                  color: Theme.text
                  echoMode: TextInput.Password
                  Keys.onReturnPressed: root.connectWithPassword(apRow.modelData.ssid, passInput.text)
                  focus: root.showPassField && root.pendingSsid === apRow.modelData.ssid
                }
              }

              Rectangle {
                width: 60; height: 28; radius: 6
                color: Theme.accent
                Text {
                  anchors.centerIn: parent
                  font.family: Theme.font; font.pixelSize: 12; font.bold: true
                  color: Theme.base; text: "Connect"
                }
                MouseArea {
                  anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                  onClicked: root.connectWithPassword(apRow.modelData.ssid, passInput.text)
                }
              }
            }
          }

          MouseArea {
            id: apRowHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (apRow.modelData.inUse) return
              if (root.pendingSsid === apRow.modelData.ssid && root.showPassField) return
              root.tryConnect(apRow.modelData.ssid, apRow.modelData.secured)
            }
          }

          // Spinner when connecting to this AP
          Text {
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: 8
            font.family: Theme.iconFont; font.pixelSize: 14
            color: Theme.accent
            text: "sync"
            visible: root.connecting && root.pendingSsid === apRow.modelData.ssid && !root.showPassField
            RotationAnimator on rotation {
              running: parent.visible
              from: 0; to: 360; duration: 1000; loops: Animation.Infinite
            }
          }
        }
      }

      Rectangle { width: parent.width; height: 1; color: Theme.surface1 }

      // ── disconnect footer ──
      Rectangle {
        width: parent.width; height: 30; radius: 6
        color: disconnHover.containsMouse ? Theme.surface0 : "transparent"
        visible: root.currentState !== "off" && root.currentState !== "unknown"

        RowLayout {
          anchors.fill: parent; anchors.leftMargin: 6
          spacing: 4
          Text {
            font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.urgent; text: "wifi_off"
          }
          Text {
            font.family: Theme.font; font.pixelSize: 12; color: Theme.urgent; text: "Disconnect"
          }
        }

        MouseArea {
          id: disconnHover
          anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
          onClicked: root.disconnect()
        }
      }

      Item { height: 2 }
    }
  }

  // Handle connector finish: re-check if connected; if not, show password field
  Connections {
    target: connector
    function onRunningChanged() {
      if (!connector.running && root.connecting) {
        root.connecting = false
        postConnectTimer.restart()
      }
    }
  }

  Timer {
    id: postConnectTimer
    interval: 1200
    onTriggered: {
      statusPoller.running = true
      apScanner.running = true
      // Check: if pendingSsid is still not the currentSsid, prompt for password
      checkConnectedTimer.restart()
    }
  }

  Timer {
    id: checkConnectedTimer
    interval: 1500
    onTriggered: {
      if (root.pendingSsid !== "" && root.currentSsid !== root.pendingSsid) {
        root.showPassField = true
        root.connectError  = "Authentication failed"
      } else {
        root.pendingSsid  = ""
        root.showPassField = false
        root.connectError  = ""
      }
    }
  }
}
