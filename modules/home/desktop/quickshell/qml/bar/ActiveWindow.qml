import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  implicitWidth: Math.min(title.width, 300)
  implicitHeight: title.height

  property string titleText: ""

  Process {
    id: poller
    command: ["sh", "-c", "niri msg action active-window get-title 2>/dev/null || echo ''"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: root.titleText = text.trim()
    }
  }

  Timer { interval: 500; running: true; repeat: true; onTriggered: poller.running = true }

  Text {
    id: title
    font.family: Theme.font
    font.pixelSize: 13
    font.weight: Font.Medium
    color: Theme.text
    text: root.titleText
    elide: Text.ElideMiddle
    width: 300
  }
}