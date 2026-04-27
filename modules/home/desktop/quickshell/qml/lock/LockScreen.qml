import Quickshell
import Quickshell.Wayland
import QtQuick

import ".."

Scope {
  id: root
  function lock() {
    locker.locked = true;
    // Pause stasis while the screen is locked: ext_idle_notifier_v1 does not
    // reset idle time when input goes to the ext-session-lock surface, so
    // without this stasis would re-fire the lock command every 180 s.
    Quickshell.execDetached(["stasis", "pause"]);
  }

  LockContext {
    id: lockContext
    onUnlocked: {
      locker.locked = false;
      lockContext.currentText = "";
      lockContext.showFailure = false;
      Quickshell.execDetached(["stasis", "resume"]);
    }
  }

  WlSessionLock {
    id: locker

    WlSessionLockSurface {
      Rectangle {
        anchors.fill: parent
        color: Theme.crust

        // Wallpaper — falls back to solid color if file doesn't exist
        Image {
          anchors.fill: parent
          source: "file:///home/p/.wallpaper/current.jpg"
          fillMode: Image.PreserveAspectCrop
          visible: status === Image.Ready
        }

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
              text: lockContext.currentText
              onTextChanged: lockContext.currentText = text
              Keys.onReturnPressed: lockContext.tryUnlock()
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.font; font.pixelSize: 14; color: lockContext.showFailure ? Theme.red : Theme.muted
            text: lockContext.showFailure ? "incorrect password" : "press enter to unlock"
          }
        }
      }
    }
  }
}