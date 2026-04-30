// Weather chip. Click opens weather flyout.
import QtQuick
import QtQuick.Layouts
import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight

  property bool tooltipShown: false

  RowLayout {
    id: row; anchors.centerIn: parent; spacing: 4
    Text { font.family: Theme.iconFont; font.pixelSize: 16; color: Theme.sky; text: WeatherModel.code }
    Text { font.family: Theme.font; font.pixelSize: 12; color: Theme.subtext
           text: WeatherModel.loading ? "…" : WeatherModel.temp }
  }

  MouseArea {
    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
    onClicked: FlyoutManager.toggle("weather")
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); root.tooltipShown = false }
    Timer { id: tipTimer; interval: 600; onTriggered: root.tooltipShown = true }
  }
}
