// Clock flyout: large time + mini calendar for the current month.
import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts

import "../.."

PanelWindow {
  id: root

  visible: FlyoutManager.active === "clock"
  color: "transparent"
  WlrLayershell.layer: WlrLayershell.Overlay
  WlrLayershell.namespace: "quickshell-flyout-clock"
  anchors { top: true; right: true }
  margins { top: Theme.barHeight + Theme.gap * 2; right: Theme.gap }
  implicitWidth: 240
  implicitHeight: card.implicitHeight

  property var now: new Date()

  Timer {
    interval: 1000; running: root.visible; repeat: true
    onTriggered: root.now = new Date()
  }

  // Build calendar data: array of {day (1-31 or 0=filler), isToday, isPrev/NextMonth}
  function buildCalendar(date) {
    const year  = date.getFullYear()
    const month = date.getMonth()
    const today = date.getDate()

    const firstDay = new Date(year, month, 1).getDay()  // 0=Sun
    // Shift so Monday=0
    const startOffset = (firstDay + 6) % 7

    const daysInMonth = new Date(year, month + 1, 0).getDate()
    const daysInPrev  = new Date(year, month, 0).getDate()

    const cells = []
    // Leading days from previous month
    for (let i = startOffset - 1; i >= 0; i--)
      cells.push({ day: daysInPrev - i, current: false, isToday: false })
    // Current month
    for (let d = 1; d <= daysInMonth; d++)
      cells.push({ day: d, current: true, isToday: d === today })
    // Trailing days
    let trailing = 1
    while (cells.length % 7 !== 0)
      cells.push({ day: trailing++, current: false, isToday: false })

    return cells
  }

  Rectangle {
    id: card
    anchors { top: parent.top; right: parent.right }
    width: 240
    implicitHeight: col.implicitHeight + 16
    radius: Theme.radius
    color: Theme.base
    opacity: Theme.opacity
    border.color: Theme.surface1; border.width: 1

    Column {
      id: col
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 12
      anchors.topMargin: 14
      spacing: 10

      // Large time
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        font.family: Theme.monoFont; font.pixelSize: 36; font.bold: true
        color: Theme.text
        text: Qt.formatDateTime(root.now, "HH:mm:ss")
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        font.family: Theme.font; font.pixelSize: 11; color: Theme.subtext
        text: Qt.formatDateTime(root.now, "dddd, MMMM d yyyy")
      }

      Rectangle { width: parent.width; height: 1; color: Theme.surface1 }

      // Month + year header
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        font.family: Theme.font; font.pixelSize: 12; font.bold: true; color: Theme.subtext
        text: Qt.formatDateTime(root.now, "MMMM yyyy")
      }

      // Day-of-week headers (Mo–Su)
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 0
        Repeater {
          model: ["Mo","Tu","We","Th","Fr","Sa","Su"]
          delegate: Text {
            required property string modelData
            width: 30
            horizontalAlignment: Text.AlignHCenter
            font.family: Theme.font; font.pixelSize: 10; color: Theme.muted
            text: modelData
          }
        }
      }

      // Calendar grid
      Grid {
        anchors.horizontalCenter: parent.horizontalCenter
        columns: 7
        spacing: 0

        property var cells: root.buildCalendar(root.now)

        Repeater {
          model: parent.cells
          delegate: Rectangle {
            required property var modelData
            width: 30; height: 26; radius: 13
            color: modelData.isToday ? Theme.accent : "transparent"

            Text {
              anchors.centerIn: parent
              font.family: Theme.font; font.pixelSize: 11
              font.bold: modelData.isToday
              color: modelData.isToday  ? Theme.base
                   : modelData.current  ? Theme.text
                   : Theme.muted
              text: modelData.day
            }
          }
        }
      }
    }
  }
}
