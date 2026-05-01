// Power menu chip. Click → opens a flyout with session actions:
// Lock, Logout, Suspend, Hibernate, Reboot, Shutdown.
import QtQuick
import ".."

Item {
  id: root
  implicitWidth:  icon.implicitWidth + 4
  implicitHeight: icon.implicitHeight

  property bool tooltipShown: false

  Text {
    id: icon
    anchors.centerIn: parent
    font.family: Theme.iconFont; font.pixelSize: 16; color: Theme.subtext
    text: "power_settings_new"
  }

  MouseArea {
    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
    onClicked: FlyoutManager.toggle("power")
    onEntered: tipTimer.start()
    onExited:  { tipTimer.stop(); root.tooltipShown = false }
    Timer { id: tipTimer; interval: 600; onTriggered: root.tooltipShown = true }
  }
}
