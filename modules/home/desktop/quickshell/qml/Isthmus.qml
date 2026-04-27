// Isthmus: plain neck rectangle connecting bar chip to flyout/tooltip card.
// The card below it has radius: Theme.radius on all corners, so its top-left
// and top-right rounded corners naturally create the concave appearance.
// No overlap with the card — card starts at y: istmusH.

import QtQuick
import "."

Rectangle {
  property real cardWidth:  parent ? parent.width : 200
  property real neckWidth:  24
  property real istmusH:    Theme.gap
  property color fillColor: Theme.base

  x:      (cardWidth - neckWidth) / 2
  y:      0
  width:  neckWidth
  height: istmusH + 2   // +2px overlap into card top to avoid seam
  color:  fillColor
  topLeftRadius:  Theme.radius / 2
  topRightRadius: Theme.radius / 2
}
