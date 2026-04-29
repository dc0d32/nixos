// Media chip. Active player selection lives in MediaState (reacts to
// player appearance/disappearance and playback-state flips). Click opens
// media flyout.
import Quickshell
import Quickshell.Services.Mpris
import QtQuick
import QtQuick.Layouts
import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight
  visible: MediaState.player !== null

  readonly property var player: MediaState.player

  property bool tooltipShown: false

  RowLayout {
    id: row; anchors.centerIn: parent; spacing: 4
    // Play/pause icon is purely decorative on the chip — the inline MouseArea
    // it used to carry was unreachable (the chip-wide MouseArea below covers
    // it and wins the click), so users got no playPause toggle from clicking
    // the icon. The full play/pause control lives in the media flyout; the
    // chip only opens the flyout now.
    Text { font.family: Theme.iconFont; font.pixelSize: 12; color: Theme.mauve
           text: (root.player && root.player.playbackState === MprisPlaybackState.Playing) ? "play_arrow" : "pause" }
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
