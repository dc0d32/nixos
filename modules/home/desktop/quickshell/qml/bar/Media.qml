import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

RowLayout {
  id: root
  spacing: 4

  property string title: ""
  property string artist: ""
  property bool playing: false

  Process {
    id: poller
    command: ["playerctl", "metadata", "--format", "{{title}}|{{artist}}|{{status}}"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        const parts = text.trim().split("|")
        if (parts.length >= 3) {
          root.title = parts[0]
          root.artist = parts[1]
          root.playing = parts[2] === "Playing"
        }
      }
    }
  }

  Timer { interval: 50; running: true; repeat: true; onTriggered: poller.running = true }

  visible: root.title !== ""

  Text {
    font.family: Theme.iconFont
    font.pixelSize: 12
    color: Theme.mauve
    text: root.playing ? "play_arrow" : "pause"
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: Quickshell.execDetached(["playerctl", "play-pause"])
    }
  }

  Text {
    font.family: Theme.font
    font.pixelSize: 11
    color: Theme.subtext
    text: root.title
    elide: Text.ElideRight
  }

  Text {
    font.family: Theme.font
    font.pixelSize: 11
    color: Theme.muted
    text: root.artist
    elide: Text.ElideRight
  }
}