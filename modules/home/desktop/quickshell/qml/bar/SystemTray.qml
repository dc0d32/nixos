import Quickshell
import Quickshell.Services.SystemTray
import QtQuick
import QtQuick.Layouts

import ".."

RowLayout {
  spacing: 6

  Repeater {
    model: SystemTray.items
    delegate: MouseArea {
      required property SystemTrayItem modelData
      implicitWidth: 18
      implicitHeight: 18
      cursorShape: Qt.PointingHandCursor
      onClicked: modelData.activate()
      onPressed: if (mouse.button === Qt.RightButton) modelData.secondaryActivate()

      Image {
        anchors.fill: parent
        source: modelData.icon
        sourceSize: Qt.size(18, 18)
        smooth: true
      }

      ToolTip.text: modelData.tooltipTitle || modelData.title || ""
      ToolTip.visible: containsMouse && ToolTip.text !== ""
      ToolTip.delay: 400
      hoverEnabled: true
    }
  }
}
