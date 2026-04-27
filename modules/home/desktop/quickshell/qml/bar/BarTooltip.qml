// Reusable hover tooltip for bar widgets.
// Renders as a top-right anchored Overlay PanelWindow so it floats above all windows.
// Place inside a widget's Item; control via `shown`. Screen is auto-detected.
//
// Usage (inside a bar widget Item):
//   MouseArea {
//     anchors.fill: parent
//     hoverEnabled: true
//     onEntered: tipTimer.start()
//     onExited:  { tipTimer.stop(); tip.shown = false }
//     Timer { id: tipTimer; interval: 600; onTriggered: tip.shown = true }
//     BarTooltip { id: tip; text: "some detail" }
//   }
import Quickshell
import Quickshell.Wayland
import QtQuick

import ".."

Scope {
  id: root

  property string text:  ""
  property bool   shown: false

  // Invisible item so the component has a visual footprint of zero
  // when used inside a layout/item tree.
  Item { width: 0; height: 0 }

  Variants {
    model: Quickshell.screens.filter(s => s === Quickshell.primaryScreen || Quickshell.screens.length === 1)
    PanelWindow {
      required property var modelData
      screen:  modelData
      visible: root.shown && root.text !== ""
      color:   "transparent"
      WlrLayershell.layer:     WlrLayershell.Overlay
      WlrLayershell.namespace: "quickshell-tooltip"

      // Sit just below the bar, pinned to the right edge
      anchors { top: true; right: true }
      margins {
        top:   Theme.barHeight + Theme.gap + 2
        right: Theme.gap
      }

      implicitWidth:  card.implicitWidth
      implicitHeight: card.implicitHeight

      Rectangle {
        id: card
        implicitWidth:  label.implicitWidth  + 16
        implicitHeight: label.implicitHeight + 10
        radius: 6
        color:  Theme.surface0
        border.color: Theme.surface2
        border.width: 1

        // Outer outline for contrast against any background
        Rectangle {
          anchors.fill: parent
          anchors.margins: -1
          radius: parent.radius + 1
          color: "transparent"
          border.color: Theme.crust
          border.width: 1
          z: -1
        }

        Text {
          id: label
          anchors.centerIn: parent
          font.family:    Theme.font
          font.pixelSize: 11
          color:          Theme.subtext
          text:           root.text
        }
      }
    }
  }
}
