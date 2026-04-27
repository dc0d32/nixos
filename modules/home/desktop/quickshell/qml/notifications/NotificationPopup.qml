// Single notification popup. Auto-hides after timeout; click X or wait to hide.
// The notification stays tracked (in history) until explicitly dismissed from the flyout.
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Layouts

import ".."

Item {
  id: root
  required property Notification notification

  // Start visible, collapse to 0 height when hidden so Column spacing works
  property bool popupShown: true
  property bool withinLimit: true

  implicitHeight: (popupShown && withinLimit) ? card.implicitHeight : 0
  visible: popupShown && withinLimit
  clip: true

  Rectangle {
    id: card
    width: parent.width
    radius: Theme.radius
    color: Theme.surface0
    opacity: Theme.opacity
    border.color: notification.urgency === NotificationUrgency.Critical
      ? Theme.urgent : Theme.surface2
    border.width: 1
    implicitHeight: row.implicitHeight + 20

    RowLayout {
      id: row
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
      spacing: 8

      Column {
        Layout.fillWidth: true
        spacing: 2

        Text {
          width: parent.width
          font.family: Theme.font; font.pixelSize: 13; font.bold: true
          color: Theme.text
          text: notification.summary
          elide: Text.ElideRight
        }
        Text {
          visible: notification.body !== ""
          width: parent.width
          font.family: Theme.font; font.pixelSize: 12
          color: Theme.subtext
          text: notification.body
          wrapMode: Text.WordWrap
          textFormat: Text.MarkdownText
        }
      }

      Text {
        text: "✕"
        font.family: Theme.font; font.pixelSize: 13
        color: Theme.muted
        Layout.alignment: Qt.AlignTop
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          // Hide popup only; notification stays in history
          onClicked: root.popupShown = false
        }
      }
    }
  }

  // Auto-hide after timeout; critical stays longer
  Timer {
    interval: notification.urgency === NotificationUrgency.Critical ? 15000 : 6000
    running: root.popupShown && root.withinLimit
    onTriggered: root.popupShown = false
  }
}
