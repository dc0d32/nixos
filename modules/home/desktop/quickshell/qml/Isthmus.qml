// Isthmus: concave neck connector between bar chip and flyout/tooltip card.
// Draws a shape that is the full card width, istmusH tall.
// The neck (neckWidth wide, centered) has:
//   - small convex rounding on the top two corners (toward the bar)
//   - concave quarter-circle cutouts at the two base corners
//     so it merges seamlessly into the card below.
//
// ASCII cross-section (y increases downward):
//
//       ╭──────╮          ← top of neck (topR convex corners)
//  ╭────╯      ╰────╮    ← concave arcs at base (concaveR)
//  │    card below  │
//
// Place at x:0, y:0. Card starts at y: istmusH.

import QtQuick
import "."

Canvas {
  id: root

  property real  cardWidth:  parent ? parent.width : 200
  property real  neckWidth:  24
  property real  istmusH:    Theme.gap
  property color fillColor:  Theme.base
  property real  concaveR:   Theme.radius
  property real  topR:       Theme.radius / 2

  width:  cardWidth
  height: istmusH

  onCardWidthChanged:  requestPaint()
  onNeckWidthChanged:  requestPaint()
  onIstmusHChanged:    requestPaint()
  onFillColorChanged:  requestPaint()
  onConcaveRChanged:   requestPaint()
  onTopRChanged:       requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.clearRect(0, 0, width, height)
    ctx.fillStyle = Qt.rgba(fillColor.r, fillColor.g, fillColor.b, fillColor.a)

    var W  = width    // full card width
    var h  = height   // istmusH

    // Neck horizontal bounds, centered
    var xL = (W - neckWidth) / 2
    var xR = xL + neckWidth

    // Clamp radii to available space
    var rT = Math.min(topR,     neckWidth / 2)
    var r  = Math.min(concaveR, (W - neckWidth) / 2, h)

    // Path: start top-left of neck, go clockwise around the outside.
    ctx.beginPath()
    ctx.moveTo(xL + rT, 0)                      // top-left (past convex corner)
    ctx.lineTo(xR - rT, 0)                      // top of neck rightward
    ctx.arcTo(xR, 0,     xR,    rT,  rT)        // top-right convex corner
    ctx.lineTo(xR, h - r)                        // right side of neck, down
    ctx.arcTo(xR, h,     xR+r,  h,   r)         // right concave corner (curves right)
    ctx.lineTo(W, h)                             // right shoulder bottom edge
    ctx.lineTo(0, h)                             // bottom edge all the way left
    ctx.arcTo(xL-r, h,   xL,    h-r, r)         // left concave corner (curves up-right)
    ctx.lineTo(xL, rT)                           // left side of neck up
    ctx.arcTo(xL, 0,     xL+rT, 0,   rT)        // top-left convex corner
    ctx.closePath()
    ctx.fill()
  }
}
