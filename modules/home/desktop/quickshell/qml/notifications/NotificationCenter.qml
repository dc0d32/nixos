// Notification popups stacked on the top-right, plus a history list.
// Subscribes to org.freedesktop.Notifications via Quickshell.Services.Notifications.
import Quickshell
import Quickshell.Services.Notifications
import Quickshell.Io
import QtQuick

import ".."

Scope {
  id: nc

  NotificationServer {
    id: server
    keepOnReload: false
    actionsSupported: true
    bodyMarkupSupported: true
    bodyImagesSupported: true
    imageSupported: true
    persistenceSupported: true
  }

  Variants {
    model: Quickshell.screens
    PanelWindow {
      required property var modelData
      screen: modelData
      anchors { top: true; right: true }
      margins { top: Theme.barHeight + Theme.gap * 2; right: Theme.gap }
      color: "transparent"
      implicitWidth: 360
      implicitHeight: col.implicitHeight + 4

      Column {
        id: col
        width: parent.width
        spacing: Theme.gap

        Repeater {
          model: server.trackedNotifications
          delegate: Rectangle {
            required property Notification modelData
            width: parent.width
            radius: Theme.radius
            color: Theme.surface0
            opacity: Theme.opacity
            border.color: modelData.urgency === NotificationUrgency.Critical
              ? Theme.urgent : Theme.surface2
            border.width: 1
            implicitHeight: nbody.implicitHeight + 20

            Column {
              id: nbody
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
              spacing: 2
              Text {
                width: parent.width
                font.family: Theme.font; font.pixelSize: 13; font.bold: true
                color: Theme.text
                text: modelData.summary
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                font.family: Theme.font; font.pixelSize: 12
                color: Theme.subtext
                text: modelData.body
                wrapMode: Text.WordWrap
                textFormat: Text.MarkdownText
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: modelData.dismiss()
            }

            Timer {
              interval: modelData.urgency === NotificationUrgency.Critical ? 15000 : 6000
              running: true
              onTriggered: modelData.expire()
            }
          }
        }
      }
    }
  }
}
