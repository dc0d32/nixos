// Brightness OSD popup. Mirrors VolumeOsd.qml: reacts to BrightnessState.percent
// changes (sourced from `udevadm monitor` on the backlight subsystem — no IPC).
// niri's brightness keybinds run `brightnessctl set ±5%` directly; the resulting
// kernel backlight change emits a udev "change" event, BrightnessState refreshes,
// and the Connections target below pops the OSD.
//
// A startup grace period suppresses the popup on initial bind so the user
// doesn't see an OSD flash every time the shell is restarted.
import Quickshell
import Quickshell.Wayland
import QtQuick

import ".."

Scope {
  id: root
  property int  value: 0      // 0..100
  property bool shown: false

  // Suppress the OSD until BrightnessState's first refresh has settled.
  // Without this, every shell restart pops the OSD with the current brightness.
  property bool armed: false
  Timer { interval: 1500; running: true; repeat: false; onTriggered: root.armed = true }

  Connections {
    target: BrightnessState
    ignoreUnknownSignals: true
    function onPercentChanged() { root._onChanged() }
  }

  function _onChanged() {
    if (!armed) return
    root.value = BrightnessState.percent
    root.shown = true
    hider.restart()
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
      // Single-anchor PanelWindows default to ExclusionMode.Auto, which
      // reserves a strip and pushes other tiled windows away. Force Ignore so
      // the OSD truly overlays.
      exclusionMode: ExclusionMode.Ignore
      anchors { top: true }
      margins { top: 100 }
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
            text: "brightness " + root.value + "%"
          }
          Rectangle {
            width: parent.width; height: 6; radius: 3; color: Theme.surface1
            Rectangle {
              width: parent.width * (root.value / 100.0); height: parent.height
              radius: 3; color: Theme.yellow
              Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
          }
        }
      }
    }
  }
}
