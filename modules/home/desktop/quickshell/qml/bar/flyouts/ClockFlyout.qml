// Clock flyout: large time + month calendar grid.
import QtQuick
import QtQuick.Layouts

import "../.."

Item {
  id: root
  property real chipCenterX: 0
  property real chipWidth:   0

  readonly property int cardWidth: 240
  readonly property int istmusW:   Math.max(chipWidth, 24)

  visible: FlyoutManager.active === "clock"

  x: Math.min(Math.max(Math.round(chipCenterX - cardWidth / 2), 0),
              (parent ? parent.width - cardWidth : 0))
  y: Theme.barHeight
  width:  cardWidth
  height: Theme.gap + col.implicitHeight + 16

  property var now: new Date()
  Timer { interval: 1000; running: root.visible; repeat: true; onTriggered: root.now = new Date() }

  function buildCalendar(date) {
    const year = date.getFullYear(), month = date.getMonth(), today = date.getDate()
    const firstDay = new Date(year, month, 1).getDay()
    const startOffset = (firstDay + 6) % 7
    const daysInMonth = new Date(year, month + 1, 0).getDate()
    const daysInPrev  = new Date(year, month, 0).getDate()
    const cells = []
    for (let i = startOffset - 1; i >= 0; i--)
      cells.push({ day: daysInPrev - i, current: false, isToday: false })
    for (let d = 1; d <= daysInMonth; d++)
      cells.push({ day: d, current: true, isToday: d === today })
    let t = 1
    while (cells.length % 7 !== 0) cells.push({ day: t++, current: false, isToday: false })
    return cells
  }

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
    implicitHeight: col.implicitHeight + 16
    radius: Theme.radius; color: Theme.base; opacity: Theme.opacity
    border.color: Theme.surface1; border.width: 1

    Column {
      id: col
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 12; anchors.topMargin: 14
      spacing: 10

      Text { anchors.horizontalCenter: parent.horizontalCenter
             font.family: Theme.monoFont; font.pixelSize: 36; font.bold: true; color: Theme.text
             text: Qt.formatDateTime(root.now, "HH:mm:ss") }
      Text { anchors.horizontalCenter: parent.horizontalCenter
             font.family: Theme.font; font.pixelSize: 11; color: Theme.subtext
             text: Qt.formatDateTime(root.now, "dddd, MMMM d yyyy") }

      Rectangle { width: parent.width; height: 1; color: Theme.surface1 }

      Text { anchors.horizontalCenter: parent.horizontalCenter
             font.family: Theme.font; font.pixelSize: 12; font.bold: true; color: Theme.subtext
             text: Qt.formatDateTime(root.now, "MMMM yyyy") }

      Row { anchors.horizontalCenter: parent.horizontalCenter; spacing: 0
        Repeater { model: ["Mo","Tu","We","Th","Fr","Sa","Su"]
          delegate: Text { required property string modelData
            width: 30; horizontalAlignment: Text.AlignHCenter
            font.family: Theme.font; font.pixelSize: 10; color: Theme.muted; text: modelData } } }

      Grid { anchors.horizontalCenter: parent.horizontalCenter; columns: 7; spacing: 0
             property var cells: root.buildCalendar(root.now)
        Repeater { model: parent.cells
          delegate: Rectangle { required property var modelData
            width: 30; height: 26; radius: 13
            color: modelData.isToday ? Theme.accent : "transparent"
            Text { anchors.centerIn: parent
                   font.family: Theme.font; font.pixelSize: 11; font.bold: modelData.isToday
                   color: modelData.isToday ? Theme.base : modelData.current ? Theme.text : Theme.muted
                   text: modelData.day } } } }
    }
  }
}
