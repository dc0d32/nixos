// Volume flyout: sink name, 0-150% slider, mute toggle.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

import "../.."

Item {
  id: root
  property real chipCenterX: 0
  property real chipWidth:   0

  readonly property int cardWidth: 240
  readonly property int istmusW:   Math.max(chipWidth, 24)

  visible: FlyoutManager.active === "volume"

  x: Math.min(Math.max(Math.round(chipCenterX - cardWidth / 2), 0),
              (parent ? parent.width - cardWidth : 0))
  y: Theme.barHeight
  width:  cardWidth
  height: Theme.gap + col.implicitHeight + 20

  property int    volume:   0
  property bool   muted:    false
  property string sinkName: "Default Sink"

  onVisibleChanged: { if (visible) { volPoller.running = true; sinkPoller.running = true } }

  Process {
    id: volPoller; command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]; running: false
    stdout: StdioCollector { onStreamFinished: {
      const m = text.match(/Volume:\s+([0-9.]+)(\s+\[MUTED\])?/)
      if (m) { if (!slider.pressed) root.volume = Math.round(parseFloat(m[1]) * 100); root.muted = !!m[2] }
    }}
  }
  Process {
    id: sinkPoller
    command: ["sh", "-c", "wpctl status | awk '/Audio/,0' | grep -m1 '\\*' | sed 's/.*\\* //;s/ \\[.*//'"]
    running: false
    stdout: StdioCollector { onStreamFinished: { const n = text.trim(); if (n) root.sinkName = n } }
  }
  Timer { interval: 200; running: root.visible; repeat: true; onTriggered: volPoller.running = true }

  // isthmus
  Isthmus {
    cardWidth: root.cardWidth
    neckWidth: root.istmusW
    color:     Theme.base
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
      anchors.margins: 12; anchors.topMargin: 12
      spacing: 10

      RowLayout {
        width: parent.width; spacing: 6
        Text { font.family: Theme.iconFont; font.pixelSize: 18
               color: root.muted ? Theme.muted : Theme.peach
               text: root.muted ? "volume_off" : root.volume === 0 ? "volume_mute" : root.volume < 40 ? "volume_down" : "volume_up" }
        Text { Layout.fillWidth: true; font.family: Theme.font; font.pixelSize: 13; font.bold: true
               color: Theme.text; text: root.sinkName; elide: Text.ElideRight }
        Text { font.family: Theme.font; font.pixelSize: 12
               color: root.muted ? Theme.urgent : Theme.subtext
               text: root.muted ? "muted" : root.volume + "%" }
      }

      RowLayout {
        width: parent.width; spacing: 8
        Text { font.family: Theme.font; font.pixelSize: 10; color: Theme.muted; text: "0" }
        Slider {
          id: slider; Layout.fillWidth: true; from: 0; to: 150; stepSize: 1; value: root.volume
          onMoved: Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", Math.round(slider.value) + "%"])
          background: Rectangle {
            x: slider.leftPadding; y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: slider.availableWidth; height: 4; radius: 2; color: Theme.surface1
            Rectangle { width: slider.visualPosition * parent.width; height: parent.height; radius: 2
                        color: root.muted ? Theme.muted : Theme.peach
                        Behavior on width { NumberAnimation { duration: 80 } } }
          }
          handle: Rectangle {
            x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: 14; height: 14; radius: 7; color: Theme.peach; border.color: Theme.base; border.width: 2
          }
        }
        Text { font.family: Theme.font; font.pixelSize: 10; color: Theme.muted; text: "150" }
      }

      Rectangle {
        width: parent.width; height: 32; radius: 6
        color: muteHover.containsMouse ? Theme.surface0 : "transparent"
        RowLayout { anchors.fill: parent; anchors.leftMargin: 4; spacing: 6
          Text { font.family: Theme.iconFont; font.pixelSize: 16
                 color: root.muted ? Theme.urgent : Theme.subtext
                 text: root.muted ? "volume_off" : "volume_up" }
          Text { font.family: Theme.font; font.pixelSize: 12
                 color: root.muted ? Theme.urgent : Theme.subtext
                 text: root.muted ? "Unmute" : "Mute" } }
        MouseArea { id: muteHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]) }
      }
    }
  }
}
