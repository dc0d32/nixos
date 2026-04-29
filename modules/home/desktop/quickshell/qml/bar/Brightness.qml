// Brightness chip. State comes from BrightnessState (event-driven via
// `udevadm monitor`); this file is pure rendering + scroll/click handling.
import Quickshell
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
    Text { font.family: Theme.iconFont; font.pixelSize: 14; color: Theme.yellow; text: "brightness_high" }
    Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.subtext
           text: BrightnessState.percent + "%" }
  }

  MouseArea {
    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton
    onClicked: FlyoutManager.toggle("brightness")
    onWheel: {
      Quickshell.execDetached(["brightnessctl", "set", wheel.angleDelta.y > 0 ? "+5%" : "5%-"])
      wheel.accepted = true
    }
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); root.tooltipShown = false }
    Timer { id: tipTimer; interval: 600; onTriggered: root.tooltipShown = true }
  }
}
