// Volume chip. Reads the default audio sink directly from the Pipewire
// singleton so changes propagate instantly without polling. Middle-click
// mutes, scroll adjusts, click opens flyout.
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight

  // Track the default sink so its audio sub-object emits change signals.
  PwObjectTracker {
    objects: Pipewire.defaultAudioSink ? [Pipewire.defaultAudioSink] : []
  }

  readonly property var sink:  Pipewire.defaultAudioSink
  readonly property var audio: sink ? sink.audio : null
  readonly property int  volume:       audio ? Math.round((audio.volume || 0) * 100) : 0
  readonly property bool muted:        audio ? audio.muted : false
  property bool tooltipShown: false

  RowLayout {
    id: row; anchors.centerIn: parent; spacing: 4
    Text { font.family: Theme.iconFont; font.pixelSize: 14
           color: root.muted ? Theme.muted : Theme.peach
           text: root.muted ? "volume_off" : root.volume === 0 ? "volume_mute" : root.volume < 40 ? "volume_down" : "volume_up" }
    Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.subtext
           text: root.muted ? "mute" : root.volume + "%" }
  }

  MouseArea {
    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton)
        Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
      else
        FlyoutManager.toggle("volume")
    }
    onWheel: {
      Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", wheel.angleDelta.y > 0 ? "5%+" : "5%-"])
      wheel.accepted = true
    }
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); root.tooltipShown = false }
    Timer { id: tipTimer; interval: 600; onTriggered: root.tooltipShown = true }
  }
}
