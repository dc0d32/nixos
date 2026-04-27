// Full-screen transparent overlay that catches clicks outside flyouts.
// Visible whenever any flyout is open; clicking it closes the active flyout.
import Quickshell
import Quickshell.Wayland
import QtQuick

import ".."

Scope {
  Variants {
    model: Quickshell.screens
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: FlyoutManager.active !== ""
      color: "transparent"
      WlrLayershell.layer: WlrLayershell.Overlay
      // Sit behind flyout cards (flyout cards use z:1 within their own window,
      // but across windows layer order puts this beneath them)
      WlrLayershell.namespace: "quickshell-flyout-backdrop"

      anchors { top: true; bottom: true; left: true; right: true }

      MouseArea {
        anchors.fill: parent
        onClicked: FlyoutManager.close()
      }
    }
  }
}
