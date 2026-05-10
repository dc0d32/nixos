// Isthmus: plain neck rectangle connecting bar chip to flyout/tooltip card.
// The card below it has radius: Theme.radius on all corners, so its top-left
// and top-right rounded corners naturally create the concave appearance.
// No overlap with the card — card starts at y: istmusH.
//
// `centerX` controls the horizontal center of the neck in parent-local
// coords. Default = parent.width/2 (centered on the panel) for legacy
// callers (e.g. BarTooltip); FlyoutWindow callers should pass the chip
// center expressed in panel-local coords so the neck stays anchored to
// the chip even when the panel is clamped against a screen edge. The
// neck is clamped so it never extends past the card's rounded corners
// (we keep at least `Theme.radius` of inset on each side, so the neck
// always meets the card's straight top edge cleanly).

import QtQuick
import "."

Rectangle {
  property real cardWidth:  parent ? parent.width : 200
  property real neckWidth:  24
  property real istmusH:    Theme.gap
  property color fillColor: Theme.base
  // Override to anchor the neck to a specific x within the card
  // (parent-local coords). Default centers on the card.
  property real centerX:    cardWidth / 2

  // Keep the neck inside the card's straight top edge.
  readonly property real _minCenter: Theme.radius + neckWidth / 2
  readonly property real _maxCenter: cardWidth - Theme.radius - neckWidth / 2
  readonly property real _clampedCenter:
    Math.min(Math.max(centerX, _minCenter), _maxCenter)

  x:      _clampedCenter - neckWidth / 2
  y:      0
  width:  neckWidth
  height: istmusH + 2   // +2px overlap into card top to avoid seam
  color:  fillColor
  topLeftRadius:  Theme.radius / 2
  topRightRadius: Theme.radius / 2
}
