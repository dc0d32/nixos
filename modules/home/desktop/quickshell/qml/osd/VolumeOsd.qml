// Centered OSD popup for volume/brightness changes. Listens on an IPC channel:
//   quickshellipc call osd show "volume 42" 42
// Bind volume/brightness keys to call both wpctl/brightnessctl AND this.
import Quickshell
import Quickshell.Wayland
import QtQuick

import ".."

Scope {
  id: root
  property string label: ""
  property int    value: 0     // 0..100
  property bool   shown: false

  IpcHandler {
    target: "osd"
    function show(text, pct) {
      root.label = text
      root.value = pct !== undefined ? pct : 0
      root.shown = true
      hider.restart()
    }
  }
  Timer { id: hider; interval: 1200; onTriggered: root.shown = false }

  Variants {
    model: Quickshell.screens.filter(s => s === Quickshell.primaryScreen || Quickshell.screens.length === 1)
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.shown
      color: "transparent"
      WlrLayershell.layer: WlrLayershell.Overlay
      anchors { horizontalCenter: true; verticalCenter: true }
      implicitWidth: 260; implicitHeight: 80

      Rectangle {
        anchors.fill: parent
        radius: Theme.radius
        color: Theme.base
        opacity: Theme.opacity
        border.color: Theme.surface2; border.width: 1

        Column {
          anchors.centerIn: parent; spacing: 10; width: parent.width - 24
          Text {
            width: parent.width; horizontalAlignment: Text.AlignHCenter
            font.family: Theme.font; font.pixelSize: 14; color: Theme.text
            text: root.label
          }
          Rectangle {
            width: parent.width; height: 6; radius: 3; color: Theme.surface1
            Rectangle {
              width: parent.width * (root.value / 100.0); height: parent.height
              radius: 3; color: Theme.accent
              Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
          }
        }
      }
    }
  }
}
