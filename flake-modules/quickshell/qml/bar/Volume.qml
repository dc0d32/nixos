// Volume chip. All state comes from VolumeState singleton (event-driven
// via Pipewire). Middle-click mutes, scroll adjusts, click opens flyout.
import Quickshell
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight

  property bool tooltipShown: false

  RowLayout {
    id: row; anchors.centerIn: parent; spacing: 4
    Text { font.family: Theme.iconFont; font.pixelSize: 14
           color: VolumeState.muted ? Theme.muted : Theme.peach
           text: VolumeState.muted        ? "volume_off"
               : VolumeState.volume === 0 ? "volume_mute"
               : VolumeState.volume < 40  ? "volume_down"
                                          : "volume_up" }
    Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.subtext
           text: VolumeState.muted ? "mute" : (VolumeState.volume + "%") }
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
