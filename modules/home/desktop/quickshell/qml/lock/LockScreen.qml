// Session lock via ext-session-lock-v1.
import Quickshell
import Quickshell.Wayland
import QtQuick

import ".."

Scope {
  id: root
  function lock() { locker.locked = true }

  WlSessionLock {
    id: locker
    locked: false

    WlSessionLockSurface {
      Rectangle {
        anchors.fill: parent
        color: Theme.crust

        Column {
          anchors.centerIn: parent
          spacing: 20

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.font; font.pixelSize: 64; color: Theme.text
            text: Qt.formatDateTime(new Date(), "HH:mm")
            Timer { interval: 1000; running: true; repeat: true
              onTriggered: parent.text = Qt.formatDateTime(new Date(), "HH:mm") }
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.font; font.pixelSize: 16; color: Theme.subtext
            text: Qt.formatDate(new Date(), "dddd, MMMM d")
          }

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 320; height: 44; radius: Theme.radius
            color: Theme.surface0; border.color: Theme.surface2; border.width: 1
            TextInput {
              id: pw
              anchors.fill: parent; anchors.margins: 12
              focus: true
              echoMode: TextInput.Password
              font.family: Theme.font; font.pixelSize: 16; color: Theme.text
              Keys.onReturnPressed: {
                // Quickshell doesn't authenticate on its own; hand off to swaylock
                // or run `loginctl unlock-session` from a pam-aware helper.
                // For now: treat ANY enter as unlock. Replace with a real check.
                locker.locked = false
                pw.text = ""
              }
            }
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
            text: "press enter to unlock  (replace with PAM-backed auth)"
          }
        }
      }
    }
  }
}
