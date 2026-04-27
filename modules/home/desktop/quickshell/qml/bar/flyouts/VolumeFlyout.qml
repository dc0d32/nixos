// Volume flyout: sink name, slider (0–150%), mute toggle.
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

import "../.."

PanelWindow {
  id: root

  visible: FlyoutManager.active === "volume"
  color: "transparent"
  WlrLayershell.layer: WlrLayershell.Overlay
  WlrLayershell.namespace: "quickshell-flyout-volume"
  anchors { top: true; right: true }
  margins { top: Theme.barHeight + Theme.gap * 2; right: Theme.gap }
  implicitWidth: 240
  implicitHeight: card.implicitHeight

  property int  volume: 0
  property bool muted:  false
  property string sinkName: "Default Sink"

  // Poll volume state while open
  Process {
    id: volPoller
    command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
    running: root.visible
    stdout: StdioCollector {
      onStreamFinished: {
        const m = text.match(/Volume:\s+([0-9.]+)(\s+\[MUTED\])?/)
        if (m) {
          if (!slider.pressed) root.volume = Math.round(parseFloat(m[1]) * 100)
          root.muted = !!m[2]
        }
      }
    }
  }

  // Get sink name
  Process {
    id: sinkPoller
    command: ["sh", "-c", "wpctl status | awk '/Audio/,0' | grep -m1 '\\*' | sed 's/.*\\* //;s/ \\[.*//'"]
    running: root.visible
    stdout: StdioCollector {
      onStreamFinished: {
        const n = text.trim()
        if (n) root.sinkName = n
      }
    }
  }

  Timer { interval: 200; running: root.visible; repeat: true; onTriggered: volPoller.running = true }

  Rectangle {
    id: card
    anchors { top: parent.top; right: parent.right }
    width: 240
    implicitHeight: col.implicitHeight + 16
    radius: Theme.radius
    color: Theme.base
    opacity: Theme.opacity
    border.color: Theme.surface1; border.width: 1

    Column {
      id: col
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 12
      anchors.topMargin: 12
      spacing: 10

      // Header
      RowLayout {
        width: parent.width
        spacing: 6
        Text {
          font.family: Theme.iconFont; font.pixelSize: 18
          color: root.muted ? Theme.muted : Theme.peach
          text: root.muted ? "volume_off"
              : root.volume === 0 ? "volume_mute"
              : root.volume < 40  ? "volume_down"
              : "volume_up"
        }
        Text {
          Layout.fillWidth: true
          font.family: Theme.font; font.pixelSize: 13; font.bold: true
          color: Theme.text
          text: root.sinkName
          elide: Text.ElideRight
        }
        Text {
          font.family: Theme.font; font.pixelSize: 12
          color: root.muted ? Theme.urgent : Theme.subtext
          text: root.muted ? "muted" : root.volume + "%"
        }
      }

      // Volume slider
      RowLayout {
        width: parent.width
        spacing: 8
        Text {
          font.family: Theme.font; font.pixelSize: 10; color: Theme.muted; text: "0"
        }
        Slider {
          id: slider
          Layout.fillWidth: true
          from: 0; to: 150; stepSize: 1
          value: root.volume
          onMoved: {
            Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", Math.round(slider.value) + "%"])
          }
          background: Rectangle {
            x: slider.leftPadding; y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: slider.availableWidth; height: 4; radius: 2; color: Theme.surface1
            Rectangle {
              width: slider.visualPosition * parent.width; height: parent.height
              radius: 2
              color: root.muted ? Theme.muted : Theme.peach
              Behavior on width { NumberAnimation { duration: 80 } }
            }
          }
          handle: Rectangle {
            x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: 14; height: 14; radius: 7
            color: Theme.peach
            border.color: Theme.base; border.width: 2
          }
        }
        Text {
          font.family: Theme.font; font.pixelSize: 10; color: Theme.muted; text: "150"
        }
      }

      // Mute toggle
      Rectangle {
        width: parent.width; height: 32; radius: 6
        color: muteHover.containsMouse ? Theme.surface0 : "transparent"
        RowLayout {
          anchors.fill: parent; anchors.leftMargin: 4; spacing: 6
          Text {
            font.family: Theme.iconFont; font.pixelSize: 16
            color: root.muted ? Theme.urgent : Theme.subtext
            text: root.muted ? "volume_off" : "volume_up"
          }
          Text {
            font.family: Theme.font; font.pixelSize: 12
            color: root.muted ? Theme.urgent : Theme.subtext
            text: root.muted ? "Unmute" : "Mute"
          }
        }
        MouseArea {
          id: muteHover
          anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
          onClicked: Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
        }
      }
    }
  }
}
