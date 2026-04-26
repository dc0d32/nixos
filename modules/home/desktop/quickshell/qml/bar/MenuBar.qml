import Quickshell
import QtQuick
import QtQuick.Layouts

import ".."

RowLayout {
  spacing: 4

  Text {
    font.family: Theme.iconFont
    font.pixelSize: 14
    color: Theme.subtext
    text: "menu"
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: Quickshell.execDetached(["sh", "-c", "niri msg action toggle-window-menu"])
    }
  }
}