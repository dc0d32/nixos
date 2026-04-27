// Brightness flyout: 0-100% slider.
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

  readonly property int cardWidth: 220
  readonly property int istmusW:   Math.max(chipWidth, 24)

  visible: FlyoutManager.active === "brightness"

  x: Math.min(Math.max(Math.round(chipCenterX - cardWidth / 2), 0),
              (parent ? parent.width - cardWidth : 0))
  y: Theme.barHeight
  width:  cardWidth
  height: Theme.gap + col.implicitHeight + 20

  property int brightness:    0
  property int maxBrightness: 100

  onVisibleChanged: { if (visible) { maxPoller.running = true; poller.running = true } }

  Process { id: maxPoller; command: ["brightnessctl", "max"]; running: false
    stdout: StdioCollector { onStreamFinished: { const v = parseInt(text.trim()); if (!isNaN(v) && v > 0) root.maxBrightness = v } } }
  Process { id: poller; command: ["brightnessctl", "get"]; running: false
    stdout: StdioCollector { onStreamFinished: {
      const v = parseInt(text.trim())
      if (!isNaN(v) && !slider.pressed) root.brightness = Math.round((v / root.maxBrightness) * 100)
    }} }
  Timer { interval: 200; running: root.visible; repeat: true; onTriggered: poller.running = true }

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
      anchors.margins: 14; anchors.topMargin: 14
      spacing: 10

      RowLayout {
        width: parent.width; spacing: 8
        Text { font.family: Theme.iconFont; font.pixelSize: 20; color: Theme.yellow; text: "brightness_high" }
        Text { font.family: Theme.font; font.pixelSize: 13; font.bold: true; color: Theme.text; text: "Brightness" }
        Item  { Layout.fillWidth: true }
        Text { font.family: Theme.font; font.pixelSize: 12; color: Theme.subtext; text: root.brightness + "%" }
      }

      RowLayout {
        width: parent.width; spacing: 8
        Text { font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.muted; text: "brightness_low" }
        Slider {
          id: slider; Layout.fillWidth: true; from: 1; to: 100; stepSize: 1; value: root.brightness
          onMoved: Quickshell.execDetached(["brightnessctl", "set", Math.round(slider.value) + "%"])
          background: Rectangle {
            x: slider.leftPadding; y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: slider.availableWidth; height: 4; radius: 2; color: Theme.surface1
            Rectangle { width: slider.visualPosition * parent.width; height: parent.height; radius: 2; color: Theme.yellow
                        Behavior on width { NumberAnimation { duration: 80 } } }
          }
          handle: Rectangle {
            x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: 14; height: 14; radius: 7; color: Theme.yellow; border.color: Theme.base; border.width: 2
          }
        }
        Text { font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.yellow; text: "brightness_high" }
      }
    }
  }
}
