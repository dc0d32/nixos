// Volume / mute OSD popup. Reacts directly to PipeWire change signals via
// Quickshell.Services.Pipewire — no IPC needed. niri's volume keybinds run
// `wpctl set-volume` and `wpctl set-mute` directly; the resulting volume /
// muted change on the default audio sink triggers this OSD.
//
// A startup grace period suppresses the popup on initial property bind so
// the user doesn't see an OSD flash every time the shell is restarted.
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import QtQuick

import ".."

Scope {
  id: root
  property string label: ""
  property int    value: 0     // 0..100
  property bool   shown: false

  // Suppress the OSD until the shell has been alive long enough for the
  // initial Pipewire bind to settle. Without this, every shell restart
  // pops the OSD with the current volume.
  property bool armed: false
  Timer { interval: 1500; running: true; repeat: false; onTriggered: root.armed = true }

  // Subscribe to the default sink. PwObjectTracker is required to keep the
  // node's audio sub-object alive and emitting change signals.
  PwObjectTracker {
    objects: Pipewire.defaultAudioSink ? [Pipewire.defaultAudioSink] : []
  }

  Connections {
    target: Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio : null
    ignoreUnknownSignals: true
    function onVolumesChanged() { root._onAudioChanged(false) }
    function onMutedChanged()   { root._onAudioChanged(true) }
  }

  function _onAudioChanged(fromMute) {
    if (!armed) return
    const audio = Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio : null
    if (!audio) return
    if (audio.muted) {
      root.label = "muted"
      root.value = 0
    } else {
      root.label = "volume"
      root.value = Math.round((audio.volume || 0) * 100)
    }
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
