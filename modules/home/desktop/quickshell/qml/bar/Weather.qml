// Weather bar chip. Data comes from the WeatherModel singleton (shared with flyout).
// Click to open weather flyout. Hover for tooltip.
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight

  RowLayout {
    id: row
    anchors.centerIn: parent
    spacing: 4

    Text {
      font.family: Theme.iconFont
      font.pixelSize: 16
      color: Theme.sky
      text: WeatherModel.code
    }
    Text {
      font.family: Theme.font
      font.pixelSize: 12
      color: Theme.subtext
      text: WeatherModel.loading ? "…" : WeatherModel.temp
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: FlyoutManager.toggle("weather")
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); tip.shown = false }

    Timer { id: tipTimer; interval: 600; onTriggered: tip.shown = true }

    BarTooltip {
      id: tip
      text: WeatherModel.location !== ""
          ? WeatherModel.location + ": " + WeatherModel.conditionText + ", " + WeatherModel.temp
          : WeatherModel.conditionText + ", " + WeatherModel.temp
    }
  }
}
