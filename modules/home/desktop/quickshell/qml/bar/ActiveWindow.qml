import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

RowLayout {
  id: root
  spacing: 6

  property string titleText: ""
  property string appName: ""

  Process {
    id: poller
    command: ["sh", "-c", "niri msg focused-window 2>/dev/null | head -5"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        const lines = text.split("\n")
        for (const line of lines) {
          if (line.startsWith("Title:")) {
            root.titleText = line.replace("Title:", "").trim().replace(/"/g, "")
          }
          if (line.startsWith("App ID:")) {
            root.appName = line.replace("App ID:", "").trim()
          }
        }
      }
    }
  }

  Timer { interval: 500; running: true; repeat: true; onTriggered: poller.running = true }

  Text {
    font.family: Theme.font
    font.pixelSize: 11
    color: Theme.subtext
    text: root.appName
    font.bold: true
  }

  Text {
    font.family: Theme.font
    font.pixelSize: 11
    color: Theme.text
    text: root.titleText
    elide: Text.ElideMiddle
    Layout.maximumWidth: 300
  }
}