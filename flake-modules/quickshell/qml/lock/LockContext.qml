import Quickshell
import Quickshell.Services.Pam
import QtQuick

// Two parallel PAM contexts so the user can type a password while biometrics
// (face / fingerprint) try in the background. A single PamContext executes
// the PAM stack sequentially: with our login stack the first `auth` rule is
// pam_unix(sufficient), which immediately blocks asking for a password —
// biometrics are only attempted after a wrong/missing password fails through.
//
// Splitting into two single-purpose PAM services lets us run both stacks
// concurrently and let whichever one succeeds first unlock the session:
//   - quickshell-password   defined in flake-modules/quickshell.nix
//                           (always present — every desktop host imports
//                           the quickshell NixOS module).
//   - quickshell-biometric  defined in flake-modules/biometrics.nix
//                           (only present on hosts that import biometrics).
//
// The biometric PamContext is gated on `biometricsAvailable` (face OR
// fingerprint env vars set by the quickshell HM module from the host's
// biometrics.enable signal). On hosts without biometrics the env vars are
// empty, the gate is false, and the biometric PamContext is never started —
// so we don't busy-loop a missing PAM service every 3 seconds.
Scope {
  id: root

  signal unlocked()

  // Password input buffer (bound from the TextInput in LockScreen.qml).
  property string currentText: ""
  property bool   showFailure: false

  // Which biometric methods are available on this host? Exposed so the
  // status hint can read e.g. "Password, face, or fingerprint". Set by the
  // quickshell HM module (flake-modules/quickshell.nix) from the host's
  // biometrics.enable signal.
  readonly property bool faceAvailable:        Quickshell.env("QUICKSHELL_LOCK_FACE")        !== ""
  readonly property bool fingerprintAvailable: Quickshell.env("QUICKSHELL_LOCK_FINGERPRINT") !== ""
  // Master gate for the biometric PamContext. False on hosts that don't
  // import flake-modules/biometrics.nix — in that case the
  // quickshell-biometric PAM service doesn't exist and starting the
  // PamContext would log a "no such service" error every 3 s as the
  // restart timer re-fires.
  readonly property bool biometricsAvailable:  faceAvailable || fingerprintAvailable

  // Aggregated state for LockScreen.qml hints.
  readonly property bool pamActive:           pamPassword.active || pamBiometric.active
  readonly property bool pamResponseRequired: pamPassword.responseRequired
  readonly property bool pamResponseVisible:  pamPassword.responseVisible
  readonly property string pamMessage: {
    // Prefer the password context's message (errors / "enter password"); fall
    // back to whatever the biometric context has to say while it scans.
    if (pamPassword.message  !== "") return pamPassword.message;
    if (pamBiometric.message !== "") return pamBiometric.message;
    return "";
  }
  readonly property bool pamMessageIsError: pamPassword.messageIsError
                                         || pamBiometric.messageIsError

  // Start (or restart) both PAM stacks. Called on lock and after a failure.
  // The biometric stack is only kicked off on hosts that have it; non-
  // biometric hosts run password-only.
  function startAuth() {
    root.currentText = "";
    root.showFailure = false;
    if (!pamPassword.active)  pamPassword.start();
    if (biometricsAvailable && !pamBiometric.active) pamBiometric.start();
  }

  // Submit the typed password to the password PamContext. Biometric stack
  // keeps running in parallel — if face/finger succeeds first, it wins.
  function tryUnlock() {
    if (!pamPassword.active && !pamBiometric.active) {
      startAuth();
      return;
    }
    if (pamPassword.responseRequired && currentText !== "") {
      pamPassword.respond(root.currentText);
    }
  }

  // Stop both stacks (used by LockScreen on success / teardown).
  function abortAuth() {
    if (pamPassword.active)  pamPassword.abort();
    if (pamBiometric.active) pamBiometric.abort();
  }

  onCurrentTextChanged: showFailure = false

  // ── Password stack ────────────────────────────────────────────────────────
  // PAM service: quickshell-password (pam_unix + pam_gnome_keyring), defined
  // in flake-modules/quickshell.nix.
  PamContext {
    id: pamPassword
    config: "quickshell-password"

    onCompleted: result => {
      if (result == PamResult.Success) {
        // Stop biometric scan and unlock.
        if (pamBiometric.active) pamBiometric.abort();
        root.unlocked();
        return;
      }
      // Wrong password (or other failure): show error, clear input, restart
      // the password stack so the prompt comes back. Biometric stack keeps
      // running independently (its own onCompleted handles its restart).
      root.showFailure = true;
      root.currentText = "";
      passwordRestartTimer.start();
    }
  }

  // ── Biometric stack ───────────────────────────────────────────────────────
  // PAM service: quickshell-biometric (pam_howdy → pam_fprintd → pam_deny),
  // defined in flake-modules/biometrics.nix. Only started when
  // biometricsAvailable is true; on non-biometric hosts the PamContext is
  // declared but never `start()`ed, so it never references the missing
  // PAM service. Never sets responseRequired — runs entirely on its own.
  PamContext {
    id: pamBiometric
    config: "quickshell-biometric"

    onCompleted: result => {
      if (result == PamResult.Success) {
        // Biometric win: abort password prompt and unlock.
        if (pamPassword.active) pamPassword.abort();
        root.unlocked();
        return;
      }
      // Biometric failure (no match / sensor timeout). Don't surface an
      // error to the user — the password prompt is the primary UX. Just
      // restart the biometric scan after a short delay.
      biometricRestartTimer.start();
    }
  }

  // Brief pause before restarting so the failure message is visible.
  Timer {
    id: passwordRestartTimer
    interval: 1500
    onTriggered: if (!pamPassword.active) pamPassword.start()
  }

  // Biometric restart cadence: long enough that a failed face scan doesn't
  // spin the IR camera at 100% duty cycle, short enough that the user
  // doesn't have to wait noticeably between attempts. Gated on
  // biometricsAvailable so we don't restart a non-existent PAM service.
  Timer {
    id: biometricRestartTimer
    interval: 3000
    onTriggered: if (root.biometricsAvailable && !pamBiometric.active) pamBiometric.start()
  }
}
