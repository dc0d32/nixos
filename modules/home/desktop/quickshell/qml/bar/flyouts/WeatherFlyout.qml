// Weather flyout: current conditions + 3-day forecast.
import QtQuick
import QtQuick.Layouts

import "../.."

Item {
  id: root
  property real chipCenterX: 0
  property real chipWidth:   0

  readonly property int cardWidth: 260
  readonly property int istmusW:   Math.max(chipWidth, 24)

  visible: FlyoutManager.active === "weather"

  x: Math.min(Math.max(Math.round(chipCenterX - cardWidth / 2), 0),
              (parent ? parent.width - cardWidth : 0))
  y: Theme.barHeight
  width:  cardWidth
  height: Theme.gap + col.implicitHeight + 20

  // isthmus
  Rectangle {
    x: Math.round((root.cardWidth - root.istmusW) / 2); y: 0
    width: root.istmusW; height: Theme.gap + Theme.radius
    color: Theme.base; topLeftRadius: Theme.radius / 2; topRightRadius: Theme.radius / 2
    bottomLeftRadius: 0; bottomRightRadius: 0
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

      Text { visible: WeatherModel.location !== ""; font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
             text: WeatherModel.location }

      RowLayout {
        width: parent.width; spacing: 10
        Text { font.family: Theme.iconFont; font.pixelSize: 32; color: Theme.sky; text: WeatherModel.code }
        Column { spacing: 3
          Text { font.family: Theme.font; font.pixelSize: 24; font.bold: true; color: Theme.text
                 text: WeatherModel.loading ? "…" : WeatherModel.temp }
          Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.subtext; text: WeatherModel.conditionText }
        }
      }

      Rectangle { width: parent.width; height: 1; color: Theme.surface1
                  visible: WeatherModel.dailyForecast.length > 0 }

      RowLayout {
        width: parent.width; spacing: 0
        visible: WeatherModel.dailyForecast.length > 0
        Repeater {
          model: WeatherModel.dailyForecast
          delegate: Column {
            required property var modelData
            Layout.fillWidth: true; spacing: 4
            Text { anchors.horizontalCenter: parent.horizontalCenter
                   font.family: Theme.font; font.pixelSize: 11; color: Theme.muted; text: modelData.day }
            Text { anchors.horizontalCenter: parent.horizontalCenter
                   font.family: Theme.iconFont; font.pixelSize: 20; color: Theme.sky; text: modelData.iconName }
            Text { anchors.horizontalCenter: parent.horizontalCenter
                   font.family: Theme.font; font.pixelSize: 11; font.bold: true; color: Theme.text; text: modelData.high + "°" }
            Text { anchors.horizontalCenter: parent.horizontalCenter
                   font.family: Theme.font; font.pixelSize: 11; color: Theme.muted; text: modelData.low + "°" }
          }
        }
      }
    }
  }
}
