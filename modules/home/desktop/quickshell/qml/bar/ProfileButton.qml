// Reusable button row for a power profile option.
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  implicitHeight: 36

  property string icon:   ""
  property string label:  ""
  property bool   active: false
  property color  accent: Theme.blue
  signal clicked()

  Rectangle {
    anchors.fill: parent
    radius: Theme.radius - 2
    color: root.active ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.15)
                       : hov.containsMouse ? Theme.surface1 : "transparent"
    border.color: root.active ? root.accent : "transparent"
    border.width: 1

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: 10; anchors.rightMargin: 10
      spacing: 10

      Text {
        font.family: Theme.iconFont; font.pixelSize: 18
        color: root.active ? root.accent : Theme.subtext
        text:  root.icon
      }
      Text {
        Layout.fillWidth: true
        font.family: Theme.font; font.pixelSize: 13
        color: root.active ? Theme.text : Theme.subtext
        font.bold: root.active
        text: root.label
      }
      Text {
        visible: root.active
        font.family: Theme.iconFont; font.pixelSize: 14
        color: root.accent
        text: "check"
      }
    }

    MouseArea {
      id: hov
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.clicked()
    }
  }
}
