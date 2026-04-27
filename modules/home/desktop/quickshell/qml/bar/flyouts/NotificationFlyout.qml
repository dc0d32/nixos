// Notification history flyout: shows all tracked notifications with dismiss controls.
import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Notifications

import "../.."

Item {
  id: root
  property real chipCenterX: 0
  property real chipWidth:   0
  property NotificationServer server

  readonly property int cardWidth: 320
  readonly property int istmusW:   Math.max(chipWidth, 24)
  readonly property int count: (server && server.trackedNotifications) ? server.trackedNotifications.values.length : 0
  readonly property int maxListHeight: 300  // keep total flyout under bar's 420px flyoutSpace

  visible: FlyoutManager.active === "notifications"

  x: Math.min(Math.max(Math.round(chipCenterX - cardWidth / 2), 0),
              (parent ? parent.width - cardWidth : 0))
  y: Theme.barHeight
  width:  cardWidth
  height: Theme.gap + card.implicitHeight + 16

  Isthmus {
    cardWidth: root.cardWidth
    neckWidth: root.istmusW
    fillColor: Theme.base
  }

  Rectangle {
    id: card
    x: 0; y: Theme.gap; width: root.cardWidth
    implicitHeight: col.implicitHeight + 16
    radius: Theme.radius; color: Theme.base; opacity: Theme.opacity
    border.color: Theme.surface1; border.width: 1

    Column {
      id: col
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 12; anchors.topMargin: 14
      spacing: 8

      RowLayout {
        width: parent.width
        Text {
          text: "Notifications"
          font.family: Theme.font; font.pixelSize: 13; font.bold: true
          color: Theme.text
          Layout.fillWidth: true
        }
        Text {
          visible: root.count > 0
          text: "Clear all"
          font.family: Theme.font; font.pixelSize: 11
          color: Theme.muted
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              var c = server.trackedNotifications.values.length
              for (var i = c - 1; i >= 0; i--)
                server.trackedNotifications.values[i].dismiss()
            }
          }
        }
      }

      Rectangle { width: parent.width; height: 1; color: Theme.surface1 }

      Text {
        visible: root.count === 0
        anchors.horizontalCenter: parent.horizontalCenter
        text: "No notifications"
        font.family: Theme.font; font.pixelSize: 12
        color: Theme.muted
        topPadding: 8; bottomPadding: 8
      }

      ListView {
        id: notifList
        width: parent.width
        height: Math.min(contentHeight, root.maxListHeight)
        visible: root.count > 0
        clip: true
        model: root.server ? root.server.trackedNotifications : null
        spacing: 6

        delegate: Rectangle {
          required property Notification modelData
          width: notifList.width
          radius: Theme.radius
          color: Theme.surface0
          border.color: modelData.urgency === NotificationUrgency.Critical
            ? Theme.urgent : Theme.surface2
          border.width: 1
          height: rowContent.implicitHeight + 16

          RowLayout {
            id: rowContent
            anchors { left: parent.left; right: parent.right; top: parent.top }
            anchors.margins: 10
            spacing: 8

            Column {
              Layout.fillWidth: true
              spacing: 2
              Text {
                width: parent.width
                font.family: Theme.font; font.pixelSize: 12; font.bold: true
                color: Theme.text
                text: modelData.appName !== "" ? "[" + modelData.appName + "] " + modelData.summary : modelData.summary
                elide: Text.ElideRight
              }
              Text {
                visible: modelData.body !== ""
                width: parent.width
                font.family: Theme.font; font.pixelSize: 11
                color: Theme.subtext
                text: modelData.body
                wrapMode: Text.WordWrap
                textFormat: Text.MarkdownText
                maximumLineCount: 3
                elide: Text.ElideRight
              }
            }

            Text {
              text: "✕"
              font.family: Theme.font; font.pixelSize: 12
              color: Theme.muted
              Layout.alignment: Qt.AlignTop
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: modelData.dismiss()
              }
            }
          }
        }
      }
    }
  }
}
