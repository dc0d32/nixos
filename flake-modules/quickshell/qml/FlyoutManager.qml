// Tracks which bar flyout is currently open, plus its on-screen bounding
// box. Only one flyout open at a time.
//
// `active` is the flyout's name ("" when none open). `activeX/Y/W/H` are
// the screen-space rect of the visible card+isthmus surface, written by
// the matching FlyoutWindow when it becomes visible. The dismiss canvas
// in Bar.qml subtracts this rect from its input mask so clicks inside
// the flyout fall through to the per-flyout layer surface beneath the
// canvas (niri stacks within the Top layer by map order; the canvas is
// mapped at startup and stays mapped, while per-flyout surfaces map
// lazily when shown — so the canvas always wins z-order otherwise).
//
// Retire when: per-flyout surfaces can be guaranteed to stack above the
// dismiss canvas (e.g. niri gains an explicit z-order layer rule, or
// Quickshell exposes a way to remap the canvas after each flyout opens).
//
// Usage: FlyoutManager.toggle("volume")  /  FlyoutManager.close()
pragma Singleton
import QtQuick

QtObject {
  id: root

  property string active: ""   // "" = none open

  // Screen-space rect of the active flyout's visible surface. Written
  // by FlyoutWindow on visibility change; consumed by the dismiss
  // canvas's input mask. All zero when no flyout is open.
  property real activeX: 0
  property real activeY: 0
  property real activeW: 0
  property real activeH: 0

  function toggle(name) {
    root.active = (root.active === name) ? "" : name
  }

  function close() {
    root.active = ""
  }
}
