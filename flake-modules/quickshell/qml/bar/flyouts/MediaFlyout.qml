// Media flyout: album art, track info, progress bar, prev/play/next.
// Player selection comes from MediaState; this file owns only the
// progress refresh timer (mpris position is not push-notified).
import Quickshell
import Quickshell.Services.Mpris
import QtQuick
import QtQuick.Layouts

import "../.."

Item {
  id: root
  property real chipCenterX: 0
  property real chipWidth:   0

  readonly property int cardWidth: 300
  readonly property int istmusW:   Math.max(chipWidth, 24)

  visible: FlyoutManager.active === "media" && player !== null

  x: Math.min(Math.max(Math.round(chipCenterX - cardWidth / 2), 0),
              (parent ? parent.width - cardWidth : 0))
  y: Theme.barHeight
  width:  cardWidth
  height: Theme.gap + col.implicitHeight + 20

  readonly property var player: MediaState.player

  property real position: player ? player.position : 0
  property real length:   player ? player.length   : 1
  property real progress: length > 0 ? Math.min(position / length, 1.0) : 0

  Timer { interval: 1000; running: root.visible && root.player !== null; repeat: true
          onTriggered: root.position = root.player ? root.player.position : 0 }

  // isthmus
  Isthmus {
    cardWidth: root.cardWidth
    neckWidth: root.istmusW
    fillColor: Theme.base
  }

  // card
  Rectangle {
    x: 0; y: Theme.gap; width: root.cardWidth
    implicitHeight: col.implicitHeight + 20
    radius: Theme.radius; color: Theme.base; opacity: Theme.opacity
    border.color: Theme.surface1; border.width: 1

    Column {
      id: col
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 14; anchors.topMargin: 14
      spacing: 10

      RowLayout {
        width: parent.width; spacing: 12
        Rectangle { width: 80; height: 80; radius: 8; color: Theme.surface0; clip: true
          Image { anchors.fill: parent; source: root.player ? root.player.trackArtUrl : ""
                  fillMode: Image.PreserveAspectCrop; visible: source !== "" }
          Text { anchors.centerIn: parent
                 visible: !root.player || root.player.trackArtUrl === ""
                 font.family: Theme.iconFont; font.pixelSize: 36; color: Theme.muted; text: "music_note" }
        }
        Column { Layout.fillWidth: true; spacing: 4
          Text { width: parent.width; font.family: Theme.font; font.pixelSize: 13; font.bold: true
                 color: Theme.text; text: root.player ? root.player.trackTitle : ""; elide: Text.ElideRight }
          Text { width: parent.width; font.family: Theme.font; font.pixelSize: 11; color: Theme.subtext
                 text: root.player ? root.player.trackArtist : ""; elide: Text.ElideRight }
          Text { width: parent.width; font.family: Theme.font; font.pixelSize: 10; color: Theme.muted
                 text: root.player ? (root.player.trackAlbum || "") : ""; elide: Text.ElideRight }
          Text { font.family: Theme.font; font.pixelSize: 10; color: Theme.muted
                 text: root.player ? (root.player.identity || "") : "" }
        }
      }

      Column { width: parent.width; spacing: 4
        Rectangle { width: parent.width; height: 4; radius: 2; color: Theme.surface1
          Rectangle { width: parent.width * root.progress; height: parent.height; radius: 2; color: Theme.mauve
                      Behavior on width { NumberAnimation { duration: 900; easing.type: Easing.Linear } } }
        }
        RowLayout { width: parent.width
          Text { font.family: Theme.monoFont; font.pixelSize: 10; color: Theme.muted
                 text: { const s = Math.floor(root.position / 1000000); const m = Math.floor(s/60), r = s%60; return m+":"+(r<10?"0":"")+r } }
          Item { Layout.fillWidth: true }
          Text { font.family: Theme.monoFont; font.pixelSize: 10; color: Theme.muted
                 text: { const s = Math.floor(root.length / 1000000); const m = Math.floor(s/60), r = s%60; return m+":"+(r<10?"0":"")+r } }
        }
      }

      RowLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 20
        Text { font.family: Theme.iconFont; font.pixelSize: 24
               color: (root.player && root.player.canGoPrevious) ? Theme.subtext : Theme.muted
               opacity: (root.player && root.player.canGoPrevious) ? 1.0 : 0.3
               text: "skip_previous"
               MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                           onClicked: if (root.player && root.player.canGoPrevious) root.player.previous() } }
        Rectangle { width: 40; height: 40; radius: 20; color: Theme.mauve
          Text { anchors.centerIn: parent; font.family: Theme.iconFont; font.pixelSize: 22; color: Theme.base
                 text: (root.player && root.player.playbackState === MprisPlaybackState.Playing) ? "pause" : "play_arrow" }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                      // quickshell's MprisPlayer exposes togglePlaying() (no
                      // playPause()). Guard on canTogglePlaying which is the
                      // OR of canPlay/canPause depending on current state.
                      onClicked: if (root.player && root.player.canTogglePlaying) root.player.togglePlaying() } }
        Text { font.family: Theme.iconFont; font.pixelSize: 24
               color: (root.player && root.player.canGoNext) ? Theme.subtext : Theme.muted
               opacity: (root.player && root.player.canGoNext) ? 1.0 : 0.3
               text: "skip_next"
               MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                           onClicked: if (root.player && root.player.canGoNext) root.player.next() } }
      }
    }
  }
}
