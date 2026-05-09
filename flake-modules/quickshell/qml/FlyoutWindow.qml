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
// Coordinate model: chipCenterX is published by Bar.qml in the
// chip-strip PanelWindow's local coordinates (origin = inside the
// strip's `barGutter` left margin). To translate to screen-space
// margins for this PanelWindow we add the same gutter and clamp to
// keep the surface fully on-screen.
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
  // add `barGutter` to both top and left margins to align with screen
  // space.
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
  // top: bar gutter + bar height. Card sits at y=Theme.gap inside this
  // surface, so the visible card top lands at barGutter + barHeight +
  // Theme.gap — matches the pre-refactor `y: Theme.barHeight` anchor
  // inside a surface that itself started at barGutter from the screen top.
  margins.top: barGutter + Theme.barHeight
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
}

