// Bell chip: shows notification count, opens history flyout on click.
import QtQuick
import Quickshell.Services.Notifications

import ".."

Item {
  id: root
  property NotificationServer server
  implicitWidth: pill.implicitWidth + 8
  implicitHeight: parent ? parent.height : 32

  readonly property int count: (server && server.trackedNotifications) ? server.trackedNotifications.values.length : 0

  Rectangle {
    id: pill
    anchors.centerIn: parent
    implicitWidth: row.implicitWidth + 12
    height: 22; radius: 11
    color: FlyoutManager.active === "notifications" ? Theme.surface1 : "transparent"

    Row {
      id: row
      anchors.centerIn: parent
      spacing: 4

      Text {
        font.family: Theme.iconFont; font.pixelSize: 14
        color: root.count > 0 ? Theme.text : Theme.muted
        text: root.count > 0 ? "\ue7f4" : "\ue7f5"  // notifications_active : notifications
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: root.count > 0
        font.family: Theme.font; font.pixelSize: 11; font.bold: true
        color: Theme.text
        text: root.count > 9 ? "9+" : root.count
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: FlyoutManager.toggle("notifications")
  }
}
