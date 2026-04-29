// Battery chip. Hidden on hosts without a battery.
// State comes from BatteryState (event-driven UPower wrapper); this file is
// pure rendering + click handling.
import Quickshell
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight
  visible: BatteryState.present

  property bool tooltipShown: false

  RowLayout {
    id: row; anchors.centerIn: parent; spacing: 4
    Text { font.family: Theme.iconFont; font.pixelSize: 16
           color: BatteryState.percent <= 15 ? Theme.red
                : BatteryState.charging       ? Theme.green
                                              : Theme.yellow
           text: BatteryState.charging         ? "battery_charging_full"
               : BatteryState.percent > 80     ? "battery_full"
               : BatteryState.percent > 50     ? "battery_5_bar"
               : BatteryState.percent > 20     ? "battery_3_bar"
                                               : "battery_1_bar" }
    Text { font.family: Theme.font; font.pixelSize: 12; color: Theme.subtext
           text: BatteryState.percent + "%" }
  }

  MouseArea {
    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
    onClicked: FlyoutManager.toggle("battery")
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); root.tooltipShown = false }
    Timer { id: tipTimer; interval: 600; onTriggered: root.tooltipShown = true }
  }
}
