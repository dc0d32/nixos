// FlyoutWindow: per-flyout PanelWindow (one Wayland layer surface per
// flyout) so niri can apply background-effect blur to just the flyout's
// bounding box (isthmus + card) instead of either the whole screen
// (single full-screen flyout-canvas surface) or nothing at all.
//
// Sized to the flyout's bounding box. Positioned with anchors.top +
// anchors.left + dynamic margins so the card centers on the originating
// chip. Visible only while FlyoutManager.active matches flyoutName, so
// at rest no extra layer surface is mapped.
//
// Coordinate model:
//   - chipCenterX is published by Bar.qml in the chip-strip
//     PanelWindow's local coordinates (origin = inside the strip's
//     `barGutter` left margin). To translate to screen-space margins
//     we add the same gutter and clamp to keep the surface on-screen.
//   - The bar reserves an exclusive zone of `barHeight + barGutter` px
//     along the top edge of the screen. Per the wlr-layer-shell
//     protocol, sibling layer surfaces' margins are computed from the
//     edge of the available area (i.e. past existing exclusion zones).
//     So `margins.top: barGutter` lands the surface flush against the
//     visible bottom of the bar (screen y = barHeight + 2*barGutter,
//     where barGutter accounts for both the bar's top margin and the
//     symmetric gap left by the bar's exclusive zone). DO NOT add
//     barHeight here — that double-counts the bar.
//
// niri opts surfaces with namespace "quickshell-flyout-*" back into
// the catch-all blur via a regex layer-rule in flake-modules/niri.nix
// (the "^quickshell-flyouts$" exclusion only matches the dismiss
// canvas exactly, not the per-flyout surfaces).
//
// Children declared inside a FlyoutWindow {} block (Isthmus, card
// Rectangle, etc.) become direct children of the PanelWindow content
// area, just like normal QtQuick Window children. Their existing
// positioning (Isthmus at y=0, card at y=Theme.gap) works unchanged
// because the surface bounds are exactly cardWidth × (Theme.gap +
// cardImplicitHeight + extraSlack).
//
// Click routing: the dismiss canvas in Bar.qml is mapped before any
// per-flyout surface and stays mapped, so within niri's Top layer it
// always sits ABOVE this surface. To prevent the canvas from eating
// our clicks, this window writes its screen-space rect into
// FlyoutManager.activeX/Y/W/H on visibility, and the canvas's input
// mask subtracts that rect.

import Quickshell
import Quickshell.Wayland
import QtQuick

import "."

PanelWindow {
  id: root

  // ── caller-supplied properties ──────────────────────────────────────
  property string flyoutName: ""
  property real   chipCenterX: 0
  property real   chipWidth: 0
  property int    cardWidth: 240
  // Card's intrinsic content height (the inner Rectangle's
  // implicitHeight, e.g. col.implicitHeight + 20). Bound reactively
  // so the surface grows/shrinks with content.
  property real   cardImplicitHeight: 0
  // Extra vertical slack added below the card. Matches per-flyout
  // historical values: 20 for most, 16 for ClockFlyout / NotificationFlyout.
  property int    extraSlack: 20
  // Bar's gutter margin (uniform on all four sides; Bar.qml uses 2 px).
  // chipCenterX is published in bar-local coords (post-gutter), so we
  // add `barGutter` to the left margin to align with screen space.
  // Top margin is just `barGutter` (see header note about the bar's
  // exclusive zone).
  property int    barGutter: 2

  // ── layer surface plumbing ──────────────────────────────────────────
  // No exclusiveZone: flyouts overlay other content, they don't reserve
  // workspace space (only the bar does).
  visible: FlyoutManager.active === flyoutName
  color: "transparent"
  WlrLayershell.namespace: "quickshell-flyout-" + flyoutName
  WlrLayershell.layer: WlrLayershell.Top
  WlrLayershell.exclusiveZone: 0

  anchors { top: true; left: true }
  // Land flush against the bar's visible bottom. The bar's exclusive
  // zone already pushes us past barHeight; we only need the symmetric
  // gutter margin.
  margins.top: barGutter
  // left: clamp(chipCenter - cardWidth/2, gutter, screen.width - cardWidth - gutter)
  margins.left: {
    var screenW = screen ? screen.width : 0
    var ideal   = barGutter + chipCenterX - cardWidth / 2
    var minX    = barGutter
    var maxX    = screenW - cardWidth - barGutter
    return Math.round(Math.min(Math.max(ideal, minX), maxX))
  }

  implicitWidth:  cardWidth
  implicitHeight: Theme.gap + cardImplicitHeight + extraSlack

  // Chip center expressed in this panel's local coordinates. Used by
  // child Isthmus instances to anchor the neck above the originating
  // chip even when the panel is clamped against a screen edge (in
  // which case the panel's geometric center is offset from the chip
  // center). chipCenterX is bar-local (post-gutter); margins.left is
  // screen-local (includes barGutter). Both share the same gutter
  // origin, so chip-screen-X = barGutter + chipCenterX, and
  // chip-in-panel = chip-screen-X - margins.left.
  readonly property real chipCenterInPanel:
    barGutter + chipCenterX - margins.left

  // ── publish rect to FlyoutManager so the dismiss canvas can punch
  //    a click-through hole here (see header note). Screen-space:
  //    x = margins.left
  //    y = barHeight + 2*barGutter (exclusive zone + this surface's top margin)
  //    w/h = implicitWidth/Height
  readonly property real screenX: margins.left
  readonly property real screenY: Theme.barHeight + 2 * barGutter
  readonly property real screenW: implicitWidth
  readonly property real screenH: implicitHeight

  onVisibleChanged: if (visible) publishRect()
  onScreenXChanged: if (visible) publishRect()
  onScreenYChanged: if (visible) publishRect()
  onScreenWChanged: if (visible) publishRect()
  onScreenHChanged: if (visible) publishRect()

  function publishRect() {
    FlyoutManager.activeX = screenX
    FlyoutManager.activeY = screenY
    FlyoutManager.activeW = screenW
    FlyoutManager.activeH = screenH
  }
}
