// Full-screen transparent overlay that catches clicks outside flyouts.
// Visible whenever any flyout is open; clicking it closes the active flyout.
// NOTE: not currently used — dismiss is handled by the MouseArea inside Bar.qml
// which covers the flyout zone below the bar strip when a flyout is active.
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
      WlrLayershell.namespace: "quickshell-flyout-backdrop"

      anchors { top: true; bottom: true; left: true; right: true }

      MouseArea {
        anchors.fill: parent
        onClicked: FlyoutManager.close()
      }
    }
  }
}
