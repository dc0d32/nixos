// Media flyout: album art, track info, progress bar, prev/play-pause/next.
// Uses Quickshell's MPRIS service (same player selection as MediaOsd).
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Mpris
import QtQuick
import QtQuick.Layouts

import "../.."

PanelWindow {
  id: root

  visible: FlyoutManager.active === "media" && player !== null
  color: "transparent"
  WlrLayershell.layer: WlrLayershell.Overlay
  WlrLayershell.namespace: "quickshell-flyout-media"
  anchors { top: true; right: true }
  margins { top: Theme.barHeight + Theme.gap * 2; right: Theme.gap }
  implicitWidth: 300
  implicitHeight: card.implicitHeight

  property MprisPlayer player:
    Mpris.players.values.find(p => p.playbackState === MprisPlaybackState.Playing)
    || Mpris.players.values[0]
    || null

  // Progress tracking
  property real  position: player ? player.position  : 0
  property real  length:   player ? player.length    : 1
  property real  progress: (length > 0) ? Math.min(position / length, 1.0) : 0

  Timer {
    interval: 1000; running: root.visible && player !== null; repeat: true
    onTriggered: root.position = player ? player.position : 0
  }

  Rectangle {
    id: card
    anchors { top: parent.top; right: parent.right }
    width: 300
    implicitHeight: col.implicitHeight + 20
    radius: Theme.radius
    color: Theme.base
    opacity: Theme.opacity
    border.color: Theme.surface1; border.width: 1

    Column {
      id: col
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 14
      anchors.topMargin: 14
      spacing: 10

      // Art + track info
      RowLayout {
        width: parent.width; spacing: 12

        // Album art
        Rectangle {
          width: 80; height: 80; radius: 8
          color: Theme.surface0
          clip: true

          Image {
            anchors.fill: parent
            source: root.player ? root.player.trackArtUrl : ""
            fillMode: Image.PreserveAspectCrop
            visible: source !== ""
          }

          // Placeholder icon when no art
          Text {
            anchors.centerIn: parent
            visible: root.player === null || root.player.trackArtUrl === ""
            font.family: Theme.iconFont; font.pixelSize: 36; color: Theme.muted
            text: "music_note"
          }
        }

        // Track details
        Column {
          Layout.fillWidth: true; spacing: 4

          Text {
            width: parent.width
            font.family: Theme.font; font.pixelSize: 13; font.bold: true
            color: Theme.text
            text: root.player ? root.player.trackTitle : ""
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            font.family: Theme.font; font.pixelSize: 11; color: Theme.subtext
            text: root.player ? root.player.trackArtist : ""
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            font.family: Theme.font; font.pixelSize: 10; color: Theme.muted
            text: root.player ? (root.player.trackAlbum || "") : ""
            elide: Text.ElideRight
          }
          Text {
            font.family: Theme.font; font.pixelSize: 10; color: Theme.muted
            text: root.player ? (root.player.identity || "") : ""
          }
        }
      }

      // Progress bar
      Column {
        width: parent.width; spacing: 4

        Rectangle {
          width: parent.width; height: 4; radius: 2; color: Theme.surface1
          Rectangle {
            width: parent.width * root.progress; height: parent.height
            radius: 2; color: Theme.mauve
            Behavior on width { NumberAnimation { duration: 900; easing.type: Easing.Linear } }
          }
        }

        // Time labels
        RowLayout {
          width: parent.width
          Text {
            font.family: Theme.monoFont; font.pixelSize: 10; color: Theme.muted
            text: {
              const s = Math.floor(root.position / 1000000)
              const m = Math.floor(s / 60); const r = s % 60
              return m + ":" + (r < 10 ? "0" : "") + r
            }
          }
          Item { Layout.fillWidth: true }
          Text {
            font.family: Theme.monoFont; font.pixelSize: 10; color: Theme.muted
            text: {
              const s = Math.floor(root.length / 1000000)
              const m = Math.floor(s / 60); const r = s % 60
              return m + ":" + (r < 10 ? "0" : "") + r
            }
          }
        }
      }

      // Controls: prev / play-pause / next
      RowLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 20

        Text {
          font.family: Theme.iconFont; font.pixelSize: 24
          color: (root.player && root.player.canGoPrevious) ? Theme.subtext : Theme.muted
          text: "skip_previous"
          opacity: (root.player && root.player.canGoPrevious) ? 1.0 : 0.3
          MouseArea {
            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            onClicked: if (root.player && root.player.canGoPrevious) root.player.previous()
          }
        }

        Rectangle {
          width: 40; height: 40; radius: 20
          color: Theme.mauve

          Text {
            anchors.centerIn: parent
            font.family: Theme.iconFont; font.pixelSize: 22; color: Theme.base
            text: (root.player && root.player.playbackState === MprisPlaybackState.Playing)
                ? "pause" : "play_arrow"
          }
          MouseArea {
            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            onClicked: if (root.player) root.player.playPause()
          }
        }

        Text {
          font.family: Theme.iconFont; font.pixelSize: 24
          color: (root.player && root.player.canGoNext) ? Theme.subtext : Theme.muted
          text: "skip_next"
          opacity: (root.player && root.player.canGoNext) ? 1.0 : 0.3
          MouseArea {
            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            onClicked: if (root.player && root.player.canGoNext) root.player.next()
          }
        }
      }
    }
  }
}
