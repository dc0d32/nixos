import QtQuick
import ".."

Text {
  id: clock
  font.family: Theme.font
  font.pixelSize: 13
  color: Theme.text
  text: Qt.formatDateTime(new Date(), "ddd  yyyy-MM-dd   HH:mm")

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: clock.text = Qt.formatDateTime(new Date(), "ddd  yyyy-MM-dd   HH:mm")
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    // Hook: toggle a calendar popup here later if desired.
  }
}
