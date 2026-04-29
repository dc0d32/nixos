import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects

import ".."

Scope {
  id: root

  // Idempotent lock(): triggered via `quickshell ipc call lock lock`. If the
  // lockscreen is already up (e.g. user pressed Super+Alt+L twice, or stasis
  // re-fires before we've torn down), do nothing — re-running startAuth()
  // would abort an in-flight biometric scan and reset the password buffer.
  function lock() {
    if (locker.locked) return;
    locker.locked = true;
    // Pause stasis so its dpms/suspend countdown doesn't fire while the
    // user is mid-unlock. Symmetric resume happens in teardown() — we route
    // every exit path through it so the daemon never gets stranded paused.
    Quickshell.execDetached(["stasis", "pause"]);
    lockContext.startAuth();
  }

  // Single teardown path: called on successful unlock. Aborts any in-flight
  // PAM contexts, clears state, resumes stasis. Made symmetric so any future
  // dismissal path (manual unlock, session signal) goes through here.
  function teardown() {
    lockContext.abortAuth();
    lockContext.currentText = "";
    lockContext.showFailure = false;
    locker.locked = false;
    Quickshell.execDetached(["stasis", "resume"]);
  }

  LockContext {
    id: lockContext
    onUnlocked: root.teardown()
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
          // The wallpaper daemon (modules/home/desktop/wallpaper.nix) keeps
          // ~/.wallpaper/current.jpg as a stable symlink to the latest fetched
          // image. Resolve $HOME at runtime so this works for any user.
          source: "file://" + Quickshell.env("HOME") + "/.wallpaper/current.jpg"
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

          // Status / hint line. With dual PamContexts the password prompt is
          // always available, so the hint advertises every accepted method.
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.font; font.pixelSize: 13
            color: lockContext.showFailure ? Theme.red
                 : lockContext.pamMessageIsError ? Theme.red
                 : Theme.muted
            text: {
              if (lockContext.showFailure) return "authentication failed"
              // Build "Password[, face][, fingerprint]" from availability flags.
              var methods = ["password"];
              if (lockContext.faceAvailable)        methods.push("face");
              if (lockContext.fingerprintAvailable) methods.push("fingerprint");
              if (methods.length === 1) return "enter password";
              if (methods.length === 2) return methods[0] + " or " + methods[1];
              // Oxford "or" for 3+: "password, face, or fingerprint".
              return methods.slice(0, -1).join(", ") + ", or " + methods[methods.length - 1];
            }
          }

          // Password input — always shown so the user can start typing
          // immediately on lock without waiting for PAM to ask. Biometric
          // scan runs in parallel (LockContext.pamBiometric).
          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 320; height: 44; radius: Theme.radius
            color: Theme.surface0
            border.color: pw.activeFocus ? Theme.accent : Theme.surface2
            border.width: 1

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
        }

        // Global key handler: Enter submits even if focus drifted off pw.
        Keys.onReturnPressed: lockContext.tryUnlock()
        focus: true
      }
    }
  }
}
