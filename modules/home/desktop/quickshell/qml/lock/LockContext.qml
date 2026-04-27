import Quickshell
import Quickshell.Services.Pam
import QtQuick

Scope {
  id: root

  signal unlocked()

  property string currentText: ""
  property bool showFailure: false

  // Start PAM immediately — biometrics (howdy/fprintd) run without user input.
  // PAM will fire responseRequired=true only when it falls through to password.
  function startAuth() {
    root.currentText = "";
    root.showFailure = false;
    pam.start();
  }

  function tryUnlock() {
    if (!pam.active) {
      startAuth();
      return;
    }
    if (pam.responseRequired && currentText !== "") {
      pam.respond(root.currentText);
    }
  }

  // Expose PAM state so LockScreen.qml can show contextual hints.
  readonly property bool pamActive:           pam.active
  readonly property bool pamResponseRequired: pam.responseRequired
  readonly property bool pamResponseVisible:  pam.responseVisible
  readonly property string pamMessage:        pam.message
  readonly property bool pamMessageIsError:   pam.messageIsError

  onCurrentTextChanged: showFailure = false

  PamContext {
    id: pam
    config: "login"

    onPamMessage: {
      // When PAM needs a typed response (password fallback), wait for the
      // user to submit via Enter. For non-interactive messages (biometrics
      // working silently) there is nothing to respond to.
      if (this.responseRequired) {
        // Don't auto-respond — wait for the user to type and hit Enter.
      }
    }

    onCompleted: result => {
      if (result == PamResult.Success) {
        root.unlocked();
      } else {
        root.showFailure = true;
        root.currentText = "";
        // Restart auth so biometrics are tried again immediately.
        restartTimer.start();
      }
    }
  }

  // Brief pause before restarting so a failure message is visible.
  Timer {
    id: restartTimer
    interval: 1500
    onTriggered: root.startAuth()
  }
}
