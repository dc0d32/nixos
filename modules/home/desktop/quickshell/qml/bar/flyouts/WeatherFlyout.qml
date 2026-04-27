// Weather flyout: current conditions + 3-day forecast from WeatherModel.
import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts

import "../.."

PanelWindow {
  id: root

  visible: FlyoutManager.active === "weather"
  color: "transparent"
  WlrLayershell.layer: WlrLayershell.Overlay
  WlrLayershell.namespace: "quickshell-flyout-weather"
  anchors { top: true; right: true }
  margins { top: Theme.barHeight + Theme.gap * 2; right: Theme.gap }
  implicitWidth: 260
  implicitHeight: card.implicitHeight

  Rectangle {
    id: card
    anchors { top: parent.top; right: parent.right }
    width: 260
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

      // Location
      Text {
        visible: WeatherModel.location !== ""
        font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
        text: WeatherModel.location
      }

      // Current conditions
      RowLayout {
        width: parent.width; spacing: 10
        Text {
          font.family: Theme.iconFont; font.pixelSize: 32
          color: Theme.sky
          text: WeatherModel.code
        }
        Column {
          spacing: 3
          Text {
            font.family: Theme.font; font.pixelSize: 24; font.bold: true
            color: Theme.text
            text: WeatherModel.loading ? "…" : WeatherModel.temp
          }
          Text {
            font.family: Theme.font; font.pixelSize: 11; color: Theme.subtext
            text: WeatherModel.conditionText
          }
        }
      }

      Rectangle { width: parent.width; height: 1; color: Theme.surface1 }

      // 3-day forecast
      RowLayout {
        width: parent.width; spacing: 0
        visible: WeatherModel.dailyForecast.length > 0

        Repeater {
          model: WeatherModel.dailyForecast
          delegate: Column {
            required property var modelData
            Layout.fillWidth: true
            spacing: 4

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
              text: modelData.day
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              font.family: Theme.iconFont; font.pixelSize: 20; color: Theme.sky
              text: modelData.iconName
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              font.family: Theme.font; font.pixelSize: 11; font.bold: true; color: Theme.text
              text: modelData.high + "°"
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
              text: modelData.low + "°"
            }
          }
        }
      }
    }
  }
}
