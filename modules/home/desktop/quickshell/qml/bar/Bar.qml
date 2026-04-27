// Top bar: [Workspaces] | [ActiveWindow] | [Tray | Media | Weather] | [Net | Vol | Brightness | Clock]
// The window is intentionally taller than the visible bar strip so that flyouts
// and tooltips (plain Items) can render inside it, above other windows, without
// needing separate PanelWindows. Only Theme.barHeight + Theme.gap is exclusive.
import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts

import ".."

PanelWindow {
  id: bar

  anchors { top: true; left: true; right: true }
  margins  { top: 2; left: 2; right: 2 }

  readonly property int flyoutSpace: 420
  implicitHeight: Theme.barHeight + flyoutSpace
  color: "transparent"
  WlrLayershell.namespace: "quickshell-bar"
  WlrLayershell.layer: WlrLayershell.Top
  WlrLayershell.exclusiveZone: Theme.barHeight + 2

  // Restrict input to the visible bar strip when no flyout is open, so the
  // transparent region below doesn't eat clicks from underlying windows.
  // When a flyout is open, mask is null (whole window receives input) so the
  // dismiss MouseArea below the bar strip can fire.
  mask: FlyoutManager.active !== "" ? null : barMask
  Region { id: barMask; item: barContent }

  // ── bar strip background ──────────────────────────────────────────────
  Rectangle {
    x: 0; y: 0; width: parent.width; height: Theme.barHeight
    radius: Theme.radius; color: Theme.base; opacity: Theme.opacity
    border.color: Theme.surface1; border.width: 1
  }

  // ── dismiss backdrop ──────────────────────────────────────────────────
  MouseArea {
    x: 0; y: Theme.barHeight
    width: parent.width; height: bar.flyoutSpace
    visible: FlyoutManager.active !== ""
    onClicked: FlyoutManager.close()
  }

  // ── bar content ───────────────────────────────────────────────────────
  Item {
    id: barContent
    x: 0; y: 0; width: parent.width; height: Theme.barHeight

    RowLayout {
      id: barRow
      anchors.fill: parent
      anchors.leftMargin: 8; anchors.rightMargin: 8
      spacing: 0

      Workspaces { }
      Rectangle {
        width: 1; implicitWidth: 1; color: Theme.surface1
        Layout.leftMargin: 8; Layout.rightMargin: 8
        Layout.fillHeight: true; Layout.topMargin: 6; Layout.bottomMargin: 6
      }
      Item { Layout.fillWidth: true }

      ActiveWindow { Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter }

      Item { Layout.fillWidth: true }

      RowLayout {
        id: rightGroup1
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        spacing: 8
        SystemTray { }
        Media   { id: mediaChip }
        Weather { id: weatherChip }
      }

      Rectangle {
        width: 1; implicitWidth: 1; color: Theme.surface1
        Layout.leftMargin: 8; Layout.rightMargin: 8
        Layout.fillHeight: true; Layout.topMargin: 6; Layout.bottomMargin: 6
      }

      RowLayout {
        id: rightGroup2
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        spacing: 8
        Network    { id: networkChip }
        Volume     { id: volumeChip }
        Battery    { id: batteryChip }
        Brightness { id: brightnessChip }
        Clock      { id: clockChip }
      }
    }
  }

  // ── reactive chip center: reads .x properties so QML tracks changes ───
  // chip lives inside: bar → barContent → barRow → rightGroup{1,2} → chip
  // We walk the x chain explicitly so the binding engine re-evaluates on layout.
  function chipCX(chip) {
    // mapToItem reads are NOT reactive; instead sum the .x chain manually.
    var x = chip.x + chip.width / 2
    var p = chip.parent
    while (p && p !== bar) { x += p.x; p = p.parent }
    return x
  }

  // Each chip's center, expressed as reactive bindings on chip.x / parent.x.
  // We read enough properties that QML re-evaluates when layout changes.
  readonly property real networkCX:    networkChip.x    + networkChip.parent.x    + networkChip.parent.parent.x    + networkChip.parent.parent.parent.x    + networkChip.width    / 2
  readonly property real volumeCX:     volumeChip.x     + volumeChip.parent.x     + volumeChip.parent.parent.x     + volumeChip.parent.parent.parent.x     + volumeChip.width     / 2
  readonly property real batteryCX:    batteryChip.x    + batteryChip.parent.x    + batteryChip.parent.parent.x    + batteryChip.parent.parent.parent.x    + batteryChip.width    / 2
  readonly property real brightnessCX: brightnessChip.x + brightnessChip.parent.x + brightnessChip.parent.parent.x + brightnessChip.parent.parent.parent.x + brightnessChip.width / 2
  readonly property real clockCX:      clockChip.x      + clockChip.parent.x      + clockChip.parent.parent.x      + clockChip.parent.parent.parent.x      + clockChip.width      / 2
  readonly property real weatherCX:    weatherChip.x    + weatherChip.parent.x    + weatherChip.parent.parent.x    + weatherChip.parent.parent.parent.x    + weatherChip.width    / 2
  readonly property real mediaCX:      mediaChip.x      + mediaChip.parent.x      + mediaChip.parent.parent.x      + mediaChip.parent.parent.parent.x      + mediaChip.width      / 2

  // ── tooltips ──────────────────────────────────────────────────────────
  BarTooltip {
    chipCenterX: bar.networkCX; shown: networkChip.tooltipShown
    text: networkChip.state === "wifi"  ? "WiFi: "  + networkChip.label
        : networkChip.state === "wired" ? "Wired: " + networkChip.label
        : "Not connected"
  }
  BarTooltip {
    chipCenterX: bar.volumeCX; shown: volumeChip.tooltipShown
    text: volumeChip.muted ? "Muted" : "Volume: " + volumeChip.volume + "%"
  }
  BarTooltip {
    chipCenterX: bar.batteryCX; shown: batteryChip.tooltipShown && batteryChip.present
    text: "Battery: " + batteryChip.percent + "% — " + batteryChip.status
  }
  BarTooltip {
    chipCenterX: bar.brightnessCX; shown: brightnessChip.tooltipShown
    text: "Brightness: " + brightnessChip.brightness + "%"
  }
  BarTooltip {
    chipCenterX: bar.clockCX; shown: clockChip.tooltipShown
    text: Qt.formatDateTime(new Date(), "dddd, MMMM d yyyy")
  }
  BarTooltip {
    chipCenterX: bar.weatherCX; shown: weatherChip.tooltipShown
    text: WeatherModel.location !== ""
        ? WeatherModel.location + ": " + WeatherModel.conditionText + ", " + WeatherModel.temp
        : WeatherModel.conditionText + ", " + WeatherModel.temp
  }
  BarTooltip {
    chipCenterX: bar.mediaCX; shown: mediaChip.tooltipShown
    text: mediaChip.player ? (mediaChip.player.trackTitle + " · " + mediaChip.player.trackArtist) : ""
  }

  // ── flyouts ───────────────────────────────────────────────────────────
  NetworkFlyout    { chipCenterX: bar.networkCX;    chipWidth: networkChip.width }
  VolumeFlyout     { chipCenterX: bar.volumeCX;     chipWidth: volumeChip.width }
  BatteryFlyout    { chipCenterX: bar.batteryCX;    chipWidth: batteryChip.width }
  WeatherFlyout    { chipCenterX: bar.weatherCX;    chipWidth: weatherChip.width }
  BrightnessFlyout { chipCenterX: bar.brightnessCX; chipWidth: brightnessChip.width }
  ClockFlyout      { chipCenterX: bar.clockCX;      chipWidth: clockChip.width }
  MediaFlyout      { chipCenterX: bar.mediaCX;      chipWidth: mediaChip.width }
}
