pragma Singleton
import QtQuick

// Catppuccin Mocha-ish palette with a few accents, centralized so widgets
// stay consistent. Edit here to retheme the whole shell.
QtObject {
  // Base surfaces
  readonly property color base:      "#1e1e2e"
  readonly property color mantle:    "#181825"
  readonly property color crust:     "#11111b"
  readonly property color surface0:  "#313244"
  readonly property color surface1:  "#45475a"
  readonly property color surface2:  "#585b70"

  // Text
  readonly property color text:      "#cdd6f4"
  readonly property color subtext:   "#a6adc8"
  readonly property color muted:     "#6c7086"

  // Colors
  readonly property color red:       "#f38ba8"

  // Accents
  readonly property color blue:      "#89b4fa"
  readonly property color mauve:     "#cba6f7"
  readonly property color pink:      "#f5c2e7"
  readonly property color peach:     "#fab387"
  readonly property color yellow:    "#f9e2af"
  readonly property color green:     "#a6e3a1"
  readonly property color teal:      "#94e2d5"
  readonly property color sky:       "#89dceb"

  // Semantics
  readonly property color accent:    blue
  readonly property color urgent:    red
  readonly property color ok:        green

  // Geometry
  readonly property int   radius:    10
  readonly property int   gap:       8
  readonly property int   barHeight: 32

  // Surface opacity. Two values because we have two visually
  // different surface classes:
  //
  //   * `opacity` — used by the always-visible bar surface
  //     (Bar.qml + bar/flyouts/*) which lives inside the
  //     `quickshell-bar` WlrLayershell namespace. Niri layer-rule
  //     forces blur OFF for that namespace (see niri.nix), so the
  //     low value paints directly over wallpaper. The bar is short
  //     and content-sparse; see-through reads as "minimal" rather
  //     than "unreadable".
  //
  //   * `panelOpacity` — used by every other Quickshell surface
  //     (OSDs, launcher, clipboard, screenshot, notifications).
  //     These are independent layer-shell surfaces in the default
  //     namespace, so they get blur from the catch-all layer-rule.
  //     But they are large and content-dense (lists, multi-line
  //     text), and even with a blurred backdrop a 0.6 alpha is too
  //     transparent to read against busy wallpapers. Bumping just
  //     this class restores legibility without losing the see-
  //     through bar aesthetic.
  //
  // Retire/collapse back into one `opacity` if niri ever
  // exposes a per-surface input-region-aware blur (so the bar
  // chip strip can also blur without bleeding into the 420px
  // flyout-canvas region) AND the bar gets the same visual
  // density treatment as popups.
  readonly property real  opacity:      0.6
  readonly property real  panelOpacity: 0.85

  // Typography
  readonly property string font:     "Inter"
  readonly property string monoFont: "JetBrainsMono Nerd Font"
  readonly property string iconFont: "Material Symbols Rounded"
}