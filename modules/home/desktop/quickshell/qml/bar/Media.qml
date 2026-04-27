// Media chip. Uses MPRIS. Click opens media flyout.
import Quickshell
import Quickshell.Services.Mpris
import QtQuick
import QtQuick.Layouts
import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight
  visible: root.player !== null

  property MprisPlayer player:
    Mpris.players.values.find(p => p.playbackState === MprisPlaybackState.Playing)
    || Mpris.players.values[0] || null

  property bool tooltipShown: false

  RowLayout {
    id: row; anchors.centerIn: parent; spacing: 4
    Text { font.family: Theme.iconFont; font.pixelSize: 12; color: Theme.mauve
           text: (root.player && root.player.playbackState === MprisPlaybackState.Playing) ? "play_arrow" : "pause"
           MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                       onClicked: if (root.player) root.player.playPause() } }
    Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.subtext
           text: root.player ? root.player.trackTitle : ""; elide: Text.ElideRight; Layout.maximumWidth: 140 }
    Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
           text: root.player ? root.player.trackArtist : ""; elide: Text.ElideRight; Layout.maximumWidth: 80 }
  }

  MouseArea {
    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
    onClicked: FlyoutManager.toggle("media")
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); root.tooltipShown = false }
    Timer { id: tipTimer; interval: 600; onTriggered: root.tooltipShown = true }
  }
}
