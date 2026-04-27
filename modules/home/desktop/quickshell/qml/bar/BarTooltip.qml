// Tooltip rendered inside the bar PanelWindow, positioned below the chip.
// chipCenterX: x-center of the target widget within the bar window.
import QtQuick
import ".."

Item {
  id: root
  // Set by Bar.qml
  property real   chipCenterX: 0
  property string text:        ""
  property bool   shown:       false

  // Isthmus dimensions
  readonly property int istmusH: Theme.gap       // 8px connector
  readonly property int istmusW: 24              // narrow neck width

  visible: shown && text !== ""

  // Position the whole assembly just below the bar strip
  x: Math.round(chipCenterX - card.width / 2)
  y: Theme.barHeight

  // Clamp to window edges (will be refined per-instance if needed)
  width:  card.width
  height: istmusH + card.height

  // ── isthmus (connector neck) ──────────────────────────────────────────
  Isthmus {
    cardWidth: card.width
    neckWidth: root.istmusW
    istmusH:   root.istmusH
    color:     Theme.surface0
  }

  // ── flyout card ───────────────────────────────────────────────────────
  Rectangle {
    id: card
    x:      0
    y:      root.istmusH
    width:  label.implicitWidth + 20
    height: label.implicitHeight + 12
    radius: Theme.radius
    color:  Theme.surface0
    border.color: Theme.surface1
    border.width: 1

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
