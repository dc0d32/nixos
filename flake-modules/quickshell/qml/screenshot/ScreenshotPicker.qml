// Screenshot picker overlay. Opened via `quickshell ipc call screenshot open`.
//
// Three modes (matching the legacy keybinds in flake-modules/niri.nix):
//   Region → annotate : grim -g "$(slurp)" - | satty --filename - --copy-command 'wl-copy'
//   Screen → annotate : grim - | satty --filename - --copy-command 'wl-copy'
//   Region → clipboard: grim -g "$(slurp)" - | wl-copy
//
// Window-mode screenshots stay on niri's native binding (Alt+Print) since they
// need compositor cooperation.
//
// We close the overlay BEFORE invoking grim/slurp so neither the dim backdrop
// nor the card show up in the captured image. slurp's region selector takes
// over the screen on its own.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts

import ".."

Scope {
  id: root

  property bool shown: false

  function open()   { shown = true }
  function close()  { shown = false }
  function toggle() { shown = !shown }

  function regionAnnotate() {
    close()
    Quickshell.execDetached([
      "bash", "-c",
      "grim -g \"$(slurp)\" - | satty --filename - --copy-command 'wl-copy'"
    ])
  }
  function screenAnnotate() {
    close()
    Quickshell.execDetached([
      "bash", "-c",
      "grim - | satty --filename - --copy-command 'wl-copy'"
    ])
  }
  function regionClipboard() {
    close()
    Quickshell.execDetached([
      "bash", "-c",
      "grim -g \"$(slurp)\" - | wl-copy"
    ])
  }

  Variants {
    model: Quickshell.screens.filter(s => s === Quickshell.primaryScreen || Quickshell.screens.length === 1)
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.shown
      color: "transparent"
      WlrLayershell.layer: WlrLayershell.Overlay
      anchors { top: true; bottom: true; left: true; right: true }
      exclusiveZone: -1
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
        Rectangle { anchors.fill: parent; color: Theme.crust; opacity: 0.5 }
      }

      // ESC closes. We use Shortcut rather than Keys.onEscapePressed +
      // focus: true because PanelWindow on this Quickshell version doesn't
      // expose a top-level `focus` property — Keys handlers attached
      // directly would be unreachable.
      Shortcut {
        sequences: [ "Escape" ]
        onActivated: root.close()
      }

      Rectangle {
        anchors.centerIn: parent
        width: 480; height: card.implicitHeight + 24
        radius: Theme.radius
        color: Theme.base
        opacity: Theme.opacity
        border.color: Theme.surface1; border.width: 1

        Column {
          id: card
          anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
          anchors.margins: 16
          spacing: 10

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.font; font.pixelSize: 14; font.bold: true
            color: Theme.text; text: "Screenshot"
          }

          ProfileButton {
            width: parent.width
            icon: "crop_free"; label: "Region → annotate"; accent: Theme.blue
            onClicked: root.regionAnnotate()
          }
          ProfileButton {
            width: parent.width
            icon: "fullscreen"; label: "Screen → annotate"; accent: Theme.mauve
            onClicked: root.screenAnnotate()
          }
          ProfileButton {
            width: parent.width
            icon: "content_copy"; label: "Region → clipboard"; accent: Theme.teal
            onClicked: root.regionClipboard()
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.family: Theme.font; font.pixelSize: 10; color: Theme.muted
            text: "Window: use Alt+Print (niri native)"
            topPadding: 4
          }
        }
      }
    }
  }

  IpcHandler {
    target: "screenshot"
    function open()   { root.open() }
    function close()  { root.close() }
    function toggle() { root.toggle() }
  }
}
