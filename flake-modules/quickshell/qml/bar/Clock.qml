// Clock chip. Click opens calendar flyout.
import QtQuick
import ".."

Item {
  id: root
  implicitWidth:  clock.implicitWidth
  implicitHeight: clock.implicitHeight

  property bool tooltipShown: false

  Text {
    id: clock; anchors.centerIn: parent
    font.family: Theme.font; font.pixelSize: 11; color: Theme.text
    text: Qt.formatDateTime(new Date(), "ddd  yyyy-MM-dd   HH:mm")
    Timer { interval: 1000; running: true; repeat: true
            onTriggered: clock.text = Qt.formatDateTime(new Date(), "ddd  yyyy-MM-dd   HH:mm") }
  }

  MouseArea {
    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
    onClicked: FlyoutManager.toggle("clock")
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); root.tooltipShown = false }
    Timer { id: tipTimer; interval: 600; onTriggered: root.tooltipShown = true }
  }
}
