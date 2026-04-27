// Isthmus (connector neck) between the bar chip and a flyout/tooltip card.
// Draws a narrow neck at the top, widening to cardWidth at the bottom, with
// concave quarter-circle cutouts at the base-left and base-right so it looks
// seamlessly attached to the card below it.
//
// Usage: place this at y:0 inside the flyout/tooltip Item, above the card.
// The card should start at y: istmusH.
//
//   ┌──────────────────────────────────────────────────────────┐  ← bar bottom
//   │              ╭──────────╮                                │
//   │  ╭───────────╯          ╰───────────╮                    │
//   │  │         card content             │                    │
//   └──────────────────────────────────────────────────────────┘
//        ↑ concave arcs here, at base of neck
//
// Properties:
//   cardWidth  – total width of the popup card (== parent.width)
//   neckWidth  – width of the narrow neck (defaults to 24 or chipWidth)
//   istmusH    – height of the isthmus (defaults to Theme.gap)
//   color      – fill color (match card background)
//   concaveR   – radius of the concave corner arcs (defaults to Theme.radius)
//   topR       – radius of the convex top corners of the neck (defaults to Theme.radius/2)

import QtQuick
import "."

Canvas {
  id: root

  property real cardWidth:  parent ? parent.width : 200
  property real neckWidth:  24
  property real istmusH:    Theme.gap
  property color color:     Theme.base
  property real concaveR:   Theme.radius
  property real topR:       Theme.radius / 2

  width:  cardWidth
  height: istmusH

  onCardWidthChanged:  requestPaint()
  onNeckWidthChanged:  requestPaint()
  onIstmusHChanged:    requestPaint()
  onColorChanged:      requestPaint()
  onConcaveRChanged:   requestPaint()
  onTopRChanged:       requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.clearRect(0, 0, width, height)
    ctx.fillStyle = Qt.rgba(color.r, color.g, color.b, color.a)

    // Neck edges (centered horizontally)
    var xL = (cardWidth - neckWidth) / 2   // left edge of neck
    var xR = xL + neckWidth                 // right edge of neck
    var h  = istmusH                        // bottom y of isthmus (top of card)
    var r  = Math.min(concaveR, neckWidth / 2, h)  // safety clamp
    var rT = Math.min(topR, neckWidth / 2)

    // Path (clockwise):
    // Start at top-left of neck (after top-left convex corner)
    ctx.beginPath()
    ctx.moveTo(xL + rT, 0)
    // top edge of neck
    ctx.lineTo(xR - rT, 0)
    // top-right convex corner
    ctx.arcTo(xR, 0, xR, rT, rT)
    // right side of neck down to start of concave arc
    ctx.lineTo(xR, h - r)
    // concave arc bottom-right: center is at (xR + r, h), curves from neck
    // bottom-right inward toward card right edge
    // We go from (xR, h-r) around a circle centered at (xR + r, h),
    // from angle 180° to 270° (i.e., left arc going down-and-right)
    ctx.arc(xR + r, h, r, Math.PI, Math.PI * 1.5, false)
    // bottom edge (right wing to right edge of card) — fill to card right
    ctx.lineTo(cardWidth, h)
    // right edge of card area down — not needed, we close at bottom
    // bottom-left (mirror): from card left edge to concave arc start
    ctx.lineTo(0, h)
    // concave arc bottom-left: center at (xL - r, h)
    // go from 270° (top of circle, i.e. xL-r, h-r) to 360°/0° (right, xL, h)
    // but we're going right-to-left so we go from 270° counterclockwise ... 
    // Actually going clockwise: from (0,h) we need to arc up to (xL, h-r).
    // Center at (xL - r, h): from angle 0° to 270°? No.
    // Center (xL-r, h): angle 0° → point (xL-r+r, h) = (xL, h) ✓ start
    //                   angle 270° → point (xL-r, h-r) ✓ end (top of arc = neck bottom-left)
    // So arc from 0° to 270°, counterclockwise (anticlockwise=true in canvas = ccw)
    ctx.arc(xL - r, h, r, 0, Math.PI * 1.5, true)
    // now at (xL, h-r) — left side of neck going up
    ctx.lineTo(xL, rT)
    // top-left convex corner
    ctx.arcTo(xL, 0, xL + rT, 0, rT)
    ctx.closePath()
    ctx.fill()
  }
}
