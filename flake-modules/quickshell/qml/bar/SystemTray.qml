import Quickshell
import Quickshell.Services.SystemTray
import QtQuick
import QtQuick.Layouts

import ".."

Row {
  spacing: 4

  Repeater {
    model: SystemTray.items
    delegate: Item {
      width: 18
      height: 18

      Image {
        anchors.centerIn: parent
        width: 16
        height: 16
        source: modelData.icon
        sourceSize: Qt.size(16, 16)
        smooth: true
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: modelData.activate()
        onPressed: function(mouse) { if (mouse.button === Qt.RightButton) modelData.secondaryActivate() }
      }
    }
  }
}