// Power profile chip. Shows current profile icon; click opens flyout.
import Quickshell
import Quickshell.Services.UPower
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  implicitWidth:  row.implicitWidth
  implicitHeight: row.implicitHeight

  property bool tooltipShown: false

  readonly property string profileName:
    PowerProfiles.profile === PowerProfile.PowerSaver    ? "Power Saver"
  : PowerProfiles.profile === PowerProfile.Performance   ? "Performance"
  : "Balanced"

  readonly property string profileIcon:
    PowerProfiles.profile === PowerProfile.PowerSaver    ? "battery_saver"
  : PowerProfiles.profile === PowerProfile.Performance   ? "bolt"
  : "eco"

  readonly property color profileColor:
    PowerProfiles.profile === PowerProfile.PowerSaver    ? Theme.blue
  : PowerProfiles.profile === PowerProfile.Performance   ? Theme.red
  : Theme.green

  RowLayout {
    id: row; anchors.centerIn: parent; spacing: 4
    Text {
      font.family: Theme.iconFont; font.pixelSize: 16
      color: root.profileColor
      text: root.profileIcon
    }
  }

  MouseArea {
    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
    onClicked: FlyoutManager.toggle("powerprofile")
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); root.tooltipShown = false }
    Timer { id: tipTimer; interval: 600; onTriggered: root.tooltipShown = true }
  }
}
