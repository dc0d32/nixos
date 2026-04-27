// Niri workspaces. Queries niri via `niri msg --json workspaces`.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

RowLayout {
  id: root
  spacing: 4

  property var workspaces: []

  Process {
    id: poller
    command: ["niri", "msg", "--json", "workspaces"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.workspaces = (JSON.parse(text) || []).slice().sort((a, b) => a.idx - b.idx)
        } catch (e) {
          root.workspaces = []
        }
      }
    }
  }

  Timer {
    interval: 500
    running: true
    repeat: true
    onTriggered: poller.running = true
  }

  Repeater {
    model: root.workspaces
    delegate: Rectangle {
      required property var modelData
      implicitWidth: modelData.is_active ? 36 : 14
      implicitHeight: 14
      radius: 7
      color: modelData.is_active
        ? Theme.accent
        : (modelData.is_focused ? Theme.mauve : Theme.surface1)
      Behavior on implicitWidth { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
      Behavior on color         { ColorAnimation  { duration: 150 } }

      Text {
        anchors.centerIn: parent
        visible: modelData.is_active
        text: String(modelData.idx)
        font.family: Theme.font
        font.pixelSize: 10
        font.bold: true
        color: Theme.base
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: Quickshell.execDetached([
          "niri", "msg", "action", "focus-workspace", String(modelData.idx)
        ])
      }
    }
  }
}
