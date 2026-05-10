// Tooltip rendered as its own per-tooltip PanelWindow (Wayland layer
// surface, namespace "quickshell-tooltip-<text-hash>"), positioned
// below the originating chip. One surface per tooltip, mapped only
// while shown — same model as FlyoutWindow.
//
// Why a dedicated layer surface instead of an Item inside the flyout
// canvas: positioning a child Item inside the always-present
// flyoutCanvas surface depends on where the canvas's content origin
// lands in screen coordinates, which is fiddly for surfaces anchored
// to all four edges (the bar's exclusive zone interaction is not the
// same as for top-only-anchored siblings). Using the same anchoring
// scheme as FlyoutWindow (top+left, margins.top=barGutter) makes the
// vertical placement identical to the per-flyout panels: surface-Y=0
// lands flush against the bar's visible bottom (see FlyoutWindow.qml
// header for the layer-shell margin math).
//
// chipCenterX is published by Bar.qml in the chip-strip PanelWindow's
// local coordinates (post-gutter), so we add `barGutter` to get
// screen-space, then clamp the surface to keep it on-screen. The
// neck stays anchored to the chip via Isthmus.centerX even when the
// surface is clamped against an edge.
//
// Hidden whenever any flyout is open: a chip's hover-timer can fire
// while the user is interacting with the same chip's flyout (the
// cursor is still inside the chip's MouseArea after the click), which
// would otherwise paint the tooltip card on top of the flyout panel.
// Tooltips are visual hints for chips at rest; once a flyout is up,
// the panel itself is the affordance.
//
// niri opts surfaces with namespace "quickshell-tooltip-*" into the
// catch-all blur (the "^quickshell-flyouts$" exclusion only matches
// the dismiss canvas exactly), so each tooltip card gets the same
// frosted-glass live-composite backdrop as flyouts.
import Quickshell
import Quickshell.Wayland
import QtQuick

import ".."

PanelWindow {
  id: root

  // ── caller-supplied properties ──────────────────────────────────────
  property real   chipCenterX: 0
  property string text:        ""
  property bool   shown:       false
  // Bar's gutter margin (must match Bar.qml `bar` and `flyoutCanvas`
  // top/left/right margins so chip-X coords line up).
  property int    barGutter:   2
  // Optional id used to disambiguate Wayland namespaces between
  // tooltip instances. Defaults to a hash of the text content.
  property string tooltipId:   ""

  // ── card dimensions (computed from text) ────────────────────────────
  readonly property int  cardWidth:  Math.round(label.implicitWidth + 20)
  readonly property int  cardHeight: Math.round(label.implicitHeight + 12)
  readonly property int  istmusH:    Theme.gap
  readonly property int  istmusW:    24

  // ── visibility ──────────────────────────────────────────────────────
  visible: shown && text !== "" && FlyoutManager.active === ""
  color: "transparent"
  WlrLayershell.namespace:
    "quickshell-tooltip-" + (tooltipId !== "" ? tooltipId : Qt.md5(text).substring(0, 8))
  WlrLayershell.layer: WlrLayershell.Top
  WlrLayershell.exclusiveZone: 0

  // ── positioning ─────────────────────────────────────────────────────
  anchors { top: true; left: true }
  // Land flush against the bar's visible bottom (same math as
  // FlyoutWindow): the bar's exclusive zone covers the strip, so
  // margins.top is just the symmetric gutter.
  margins.top: barGutter
  margins.left: {
    var screenW = screen ? screen.width : 0
    var ideal   = barGutter + chipCenterX - cardWidth / 2
    var minX    = barGutter
    var maxX    = screenW - cardWidth - barGutter
    return Math.round(Math.min(Math.max(ideal, minX), maxX))
  }

  implicitWidth:  cardWidth
  implicitHeight: istmusH + cardHeight

  // Chip center in this surface's local coords. Keeps the neck pointed
  // at the chip even when the surface is clamped against a screen edge.
  readonly property real chipCenterInPanel:
    barGutter + chipCenterX - margins.left

  // ── isthmus (connector neck) ────────────────────────────────────────
  Isthmus {
    cardWidth: root.cardWidth
    neckWidth: root.istmusW
    istmusH:   root.istmusH
    centerX:   root.chipCenterInPanel
    fillColor: Theme.surface0
  }

  // ── tooltip card ────────────────────────────────────────────────────
  Rectangle {
    id: card
    x:      0
    y:      root.istmusH
    width:  root.cardWidth
    height: root.cardHeight
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
