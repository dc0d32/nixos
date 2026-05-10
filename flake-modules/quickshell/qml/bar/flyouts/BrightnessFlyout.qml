// Brightness flyout: 0-100% slider. State from BrightnessState singleton.
import Quickshell
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

import "../.."

FlyoutWindow {
  id: root
  flyoutName: "brightness"
  cardWidth: 220
  cardImplicitHeight: card.implicitHeight

  readonly property int istmusW: Math.max(chipWidth, 24)

  // isthmus
  Isthmus {
    cardWidth: root.cardWidth
    neckWidth: root.istmusW
    centerX:   root.chipCenterInPanel
    fillColor: Theme.base
  }

  // card
  Rectangle {
    id: card
    x: 0; y: Theme.gap; width: root.cardWidth
    implicitHeight: col.implicitHeight + 20
    radius: Theme.radius; color: Theme.base; opacity: Theme.panelOpacity
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
        Text { font.family: Theme.font; font.pixelSize: 12; color: Theme.subtext
               text: BrightnessState.percent + "%" }
      }

      RowLayout {
        width: parent.width; spacing: 8
        Text { font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.muted; text: "brightness_low" }
        Slider {
          id: slider; Layout.fillWidth: true; from: 1; to: 100; stepSize: 1
          // Bind to the singleton, but only when the user isn't dragging
          // — otherwise the binding fights the user's input mid-drag.
          value: slider.pressed ? slider.value : BrightnessState.percent
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
