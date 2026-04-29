import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects

import ".."

Scope {
  id: root
  function lock() {
    locker.locked = true;
    Quickshell.execDetached(["stasis", "pause"]);
    // Start biometric auth immediately on lock.
    lockContext.startAuth();
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

        Image {
          id: wallpaper
          anchors.fill: parent
          source: root.wallpaperPath
          fillMode: Image.PreserveAspectCrop
          visible: false   // hidden; MultiEffect renders it
        }

        MultiEffect {
          anchors.fill: parent
          source: wallpaper
          blurEnabled: true
          blur: 1.0
          blurMax: 64
          visible: wallpaper.status === Image.Ready
          // Dim overlay so text remains readable over any wallpaper
          colorization: 0.15
          colorizationColor: Theme.crust
        }

        Column {
          anchors.centerIn: parent
          spacing: 20

          // Clock
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

          // Status / hint line
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.font; font.pixelSize: 13
            color: lockContext.showFailure ? Theme.red
                 : lockContext.pamMessageIsError ? Theme.red
                 : Theme.muted
            text: {
              if (lockContext.showFailure)         return "authentication failed"
              if (!lockContext.pamActive)          return "press enter to unlock"
              if (lockContext.pamResponseRequired) return "enter password"
              if (lockContext.pamMessage !== "")   return lockContext.pamMessage
              return "scanning…"
            }
          }

          // Password input — only shown when PAM is asking for a typed response
          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 320; height: 44; radius: Theme.radius
            color: Theme.surface0
            border.color: lockContext.pamResponseRequired ? Theme.accent : Theme.surface2
            border.width: 1
            visible: lockContext.pamResponseRequired || lockContext.currentText !== ""
            opacity: lockContext.pamResponseRequired ? 1.0 : 0.5

            TextInput {
              id: pw
              anchors.fill: parent; anchors.margins: 12
              focus: true
              echoMode: lockContext.pamResponseVisible ? TextInput.Normal : TextInput.Password
              font.family: Theme.font; font.pixelSize: 16; color: Theme.text
              text: lockContext.currentText
              onTextChanged: lockContext.currentText = text
              Keys.onReturnPressed: lockContext.tryUnlock()
            }
          }

          // "press enter" hint when not yet active and password box is hidden
          MouseArea {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 320; height: 44
            visible: !lockContext.pamActive && !lockContext.pamResponseRequired
            cursorShape: Qt.PointingHandCursor
            onClicked: lockContext.startAuth()
            // Keyboard enter also works via the TextInput above when visible,
            // but when hidden we need a global key handler.
          }
        }

        // Global key handler: Enter starts/submits auth regardless of focus
        Keys.onReturnPressed: lockContext.tryUnlock()
        focus: true
      }
    }
  }
}
