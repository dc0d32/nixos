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

    // Path (clockwise), correct concave arcs:
    //
    //   Arc geometry for concave cutouts:
    //     Right side: center (xR, h), from angle 3π/2 to 0, CCW (anticlockwise=true)
    //       → curves inward from (xR, h-r) up-right to (xR+r, h)
    //     Left side:  center (xL, h), from angle π to 3π/2, CW (anticlockwise=false)
    //       → curves inward from (xL-r, h) up-left to (xL, h-r)  [traversed right-to-left]

    ctx.beginPath()
    ctx.moveTo(xL + rT, 0)                             // after top-left convex corner
    ctx.lineTo(xR - rT, 0)                             // top of neck
    ctx.arcTo(xR, 0, xR, rT, rT)                      // top-right convex corner
    ctx.lineTo(xR, h - r)                              // right side of neck down
    ctx.arc(xR, h, r, Math.PI * 1.5, 0, true)         // concave cutout right (CCW)
    ctx.lineTo(W, h)                                   // bottom-right to card edge
    ctx.lineTo(0, h)                                   // bottom-left across
    ctx.arc(xL, h, r, Math.PI, Math.PI * 1.5, false)  // concave cutout left (CW)
    ctx.lineTo(xL, rT)                                 // left side of neck up
    ctx.arcTo(xL, 0, xL + rT, 0, rT)                  // top-left convex corner
    ctx.closePath()
    ctx.fill()
  }
}
