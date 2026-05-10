// Battery flyout: percent, status, estimated time remaining.
// All state from BatteryState (event-driven UPower wrapper); no polling here.
import Quickshell
import QtQuick
import QtQuick.Layouts

import "../.."

FlyoutWindow {
  id: root
  flyoutName: "battery"
  cardWidth: 200
  cardImplicitHeight: card.implicitHeight

  readonly property int istmusW: Math.max(chipWidth, 24)

  // isthmus
  Isthmus {
    cardWidth: root.cardWidth
    neckWidth: root.istmusW
    centerX:   root.chipCenterInPanel
    fillColor: Theme.base
  }

  // card
  Rectangle {
    id: card
    x: 0; y: Theme.gap; width: root.cardWidth
    implicitHeight: col.implicitHeight + 20
    radius: Theme.radius; color: Theme.base; opacity: Theme.panelOpacity
    border.color: Theme.surface1; border.width: 1

    Column {
      id: col
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 14; anchors.topMargin: 14
      spacing: 10

      RowLayout {
        width: parent.width; spacing: 8
        Text { font.family: Theme.iconFont; font.pixelSize: 24
               color: BatteryState.percent <= 15 ? Theme.red
                    : BatteryState.charging       ? Theme.green
                                                  : Theme.yellow
               text: BatteryState.charging         ? "battery_charging_full"
                   : BatteryState.percent > 80     ? "battery_full"
                   : BatteryState.percent > 50     ? "battery_5_bar"
                   : BatteryState.percent > 20     ? "battery_3_bar"
                                                   : "battery_1_bar" }
        Column { spacing: 2
          Text { font.family: Theme.font; font.pixelSize: 20; font.bold: true
                 color: Theme.text; text: BatteryState.percent + "%" }
          Text { font.family: Theme.font; font.pixelSize: 11
                 color: BatteryState.charging          ? Theme.green
                      : BatteryState.percent <= 15    ? Theme.red
                                                      : Theme.subtext
                 text: BatteryState.status } }
      }

      Rectangle { width: parent.width; height: 6; radius: 3; color: Theme.surface1
        Rectangle { width: parent.width * (BatteryState.percent / 100.0); height: parent.height; radius: 3
                    color: BatteryState.percent <= 15 ? Theme.red
                         : BatteryState.charging       ? Theme.green
                                                       : Theme.yellow
                    Behavior on width { NumberAnimation { duration: 300 } } }
      }

      Text { visible: BatteryState.timeLeft !== ""
             font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
             text: BatteryState.charging
                   ? ("Full in ~" + BatteryState.timeLeft)
                   : ("~" + BatteryState.timeLeft + " remaining") }
    }
  }
}
