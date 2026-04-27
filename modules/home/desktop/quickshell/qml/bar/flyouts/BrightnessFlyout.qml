// Brightness flyout: slider (0–100%).
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

import "../.."

PanelWindow {
  id: root

  visible: FlyoutManager.active === "brightness"
  color: "transparent"
  WlrLayershell.layer: WlrLayershell.Overlay
  WlrLayershell.namespace: "quickshell-flyout-brightness"
  anchors { top: true; right: true }
  margins { top: Theme.barHeight + Theme.gap * 2; right: Theme.gap }
  implicitWidth: 220
  implicitHeight: card.implicitHeight

  property int brightness:    0
  property int maxBrightness: 100

  Process {
    id: maxPoller
    command: ["brightnessctl", "max"]
    running: root.visible
    stdout: StdioCollector {
      onStreamFinished: {
        const v = parseInt(text.trim())
        if (!isNaN(v) && v > 0) root.maxBrightness = v
      }
    }
  }

  Process {
    id: poller
    command: ["brightnessctl", "get"]
    running: root.visible
    stdout: StdioCollector {
      onStreamFinished: {
        const v = parseInt(text.trim())
        if (!isNaN(v) && !slider.pressed)
          root.brightness = Math.round((v / root.maxBrightness) * 100)
      }
    }
  }

  Timer { interval: 200; running: root.visible; repeat: true; onTriggered: poller.running = true }

  Rectangle {
    id: card
    anchors { top: parent.top; right: parent.right }
    width: 220
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

      RowLayout {
        width: parent.width; spacing: 8
        Text {
          font.family: Theme.iconFont; font.pixelSize: 20; color: Theme.yellow
          text: "brightness_high"
        }
        Text {
          font.family: Theme.font; font.pixelSize: 13; font.bold: true
          color: Theme.text; text: "Brightness"
        }
        Item { Layout.fillWidth: true }
        Text {
          font.family: Theme.font; font.pixelSize: 12; color: Theme.subtext
          text: root.brightness + "%"
        }
      }

      RowLayout {
        width: parent.width; spacing: 8
        Text { font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.muted; text: "brightness_low" }
        Slider {
          id: slider
          Layout.fillWidth: true
          from: 1; to: 100; stepSize: 1
          value: root.brightness
          onMoved: {
            Quickshell.execDetached(["brightnessctl", "set", Math.round(slider.value) + "%"])
          }
          background: Rectangle {
            x: slider.leftPadding; y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: slider.availableWidth; height: 4; radius: 2; color: Theme.surface1
            Rectangle {
              width: slider.visualPosition * parent.width; height: parent.height
              radius: 2; color: Theme.yellow
              Behavior on width { NumberAnimation { duration: 80 } }
            }
          }
          handle: Rectangle {
            x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: 14; height: 14; radius: 7
            color: Theme.yellow; border.color: Theme.base; border.width: 2
          }
        }
        Text { font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.yellow; text: "brightness_high" }
      }
    }
  }
}
