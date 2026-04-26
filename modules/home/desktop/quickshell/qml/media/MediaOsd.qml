// Now-playing widget shown on media change via MPRIS.
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Wayland
import Quickshell.Io
import QtQuick

import ".."

Scope {
  id: root

  property MprisPlayer player: Mpris.players.values.find(p => p.playbackState === MprisPlaybackState.Playing)
                              || Mpris.players.values[0]
                              || null
  property bool shown: false

  Connections {
    target: root.player
    function onTrackTitleChanged() { root.flash() }
  }
  function flash() {
    if (!root.player) return
    root.shown = true
    hideTimer.restart()
  }
  Timer { id: hideTimer; interval: 3500; onTriggered: root.shown = false }

  Variants {
    model: Quickshell.screens.filter(s => s === Quickshell.primaryScreen || Quickshell.screens.length === 1)
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.shown && root.player !== null
      color: "transparent"
      WlrLayershell.layer: WlrLayershell.Overlay
      anchors { bottom: true }
      margins { bottom: 100 }
      implicitWidth: 360
      implicitHeight: 72

      Rectangle {
        anchors.fill: parent
        radius: Theme.radius
        color: Theme.surface0
        opacity: Theme.opacity
        border.color: Theme.surface2; border.width: 1

        Row {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.leftMargin: 10
          anchors.rightMargin: 10
          anchors.topMargin: 10
          anchors.bottomMargin: 10
          spacing: 10
          Image {
            width: 52; height: 52; sourceSize: Qt.size(52,52)
            source: root.player ? root.player.trackArtUrl : ""
            visible: source !== ""
          }
          Column {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            spacing: 2
            Text { font.family: Theme.font; font.pixelSize: 13; font.bold: true; color: Theme.text
                   text: root.player ? root.player.trackTitle : "" }
            Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.subtext
                   text: root.player ? root.player.trackArtist : "" }
          }
        }
      }
    }
  }
}
