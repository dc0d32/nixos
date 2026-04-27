// Date/time widget. Click to open calendar flyout. Hover for full date tooltip.
import QtQuick
import ".."

Item {
  id: root
  implicitWidth:  clock.implicitWidth
  implicitHeight: clock.implicitHeight

  Text {
    id: clock
    anchors.centerIn: parent
    font.family: Theme.font
    font.pixelSize: 11
    color: Theme.text
    text: Qt.formatDateTime(new Date(), "ddd  yyyy-MM-dd   HH:mm")

    Timer {
      interval: 1000
      running: true
      repeat: true
      onTriggered: clock.text = Qt.formatDateTime(new Date(), "ddd  yyyy-MM-dd   HH:mm")
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: FlyoutManager.toggle("clock")
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); tip.shown = false }

    Timer { id: tipTimer; interval: 600; onTriggered: tip.shown = true }

    BarTooltip {
      id: tip
      text: Qt.formatDateTime(new Date(), "dddd, MMMM d yyyy")
    }
  }
}
