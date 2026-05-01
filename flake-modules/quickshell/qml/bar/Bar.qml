// Top bar: [Workspaces] | [ActiveWindow] | [Tray | Media | Weather] | [Notifs | Net | Vol | Brightness | Clock]
// The window is intentionally taller than the visible bar strip so that flyouts
// and tooltips (plain Items) can render inside it, above other windows, without
// needing separate PanelWindows. Only Theme.barHeight + Theme.gap is exclusive.
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Layouts

import ".."

PanelWindow {
  id: bar

  property NotificationServer notificationServer

  anchors { top: true; left: true; right: true }
  margins  { top: 2; left: 2; right: 2 }

  readonly property int flyoutSpace: 420
  // When a flyout is open, balloon the window to cover the whole screen so a
  // click anywhere outside the flyout card (incl. far below it, on top of
  // other apps) hits the dismiss MouseArea below. Layer-shell windows don't
  // forward unhandled clicks to surfaces underneath, so without this growth
  // a click on a browser/terminal just goes to that window and the flyout
  // stays open. exclusiveZone stays at barHeight; only the *input* area
  // grows. Tiled windows are unaffected (they're laid out per exclusiveZone,
  // not per window height).
  readonly property bool flyoutOpen: FlyoutManager.active !== ""
  implicitHeight: flyoutOpen
                  ? (screen ? screen.height : Theme.barHeight + flyoutSpace)
                  : Theme.barHeight + flyoutSpace
  color: "transparent"
  WlrLayershell.namespace: "quickshell-bar"
  WlrLayershell.layer: WlrLayershell.Top
  WlrLayershell.exclusiveZone: Theme.barHeight + 2

  // Restrict input to the visible bar strip when no flyout is open, so the
  // transparent region below doesn't eat clicks from underlying windows.
  // When a flyout is open, mask is null (whole window receives input) so the
  // dismiss MouseArea below the bar strip can fire.
  mask: flyoutOpen ? null : barMask
  Region { id: barMask; item: barContent }

  // ── bar strip background ──────────────────────────────────────────────
  Rectangle {
    x: 0; y: 0; width: parent.width; height: Theme.barHeight
    radius: Theme.radius; color: Theme.base; opacity: Theme.opacity
    border.color: Theme.surface1; border.width: 1
  }

  // ── dismiss backdrop ──────────────────────────────────────────────────
  // Covers everything below the bar strip down to the bottom of the (now
  // full-screen) window when a flyout is open. Flyouts render *above* this
  // (later in declaration order) so their cards still receive clicks.
  MouseArea {
    x: 0; y: Theme.barHeight
    width: parent.width
    height: parent.height - Theme.barHeight
    visible: bar.flyoutOpen
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
        Bluetooth  { id: bluetoothChip }
        Volume     { id: volumeChip }
        Battery    { id: batteryChip }
        PowerProfile { id: powerProfileChip }
        Brightness { id: brightnessChip }
        Clock      { id: clockChip }
        PowerChip  { id: powerChip }
        NotificationChip { id: notifChip; server: bar.notificationServer }
      }
    }
  }

  // ── reactive chip center ──────────────────────────────────────────────
  // mapToItem() is NOT reactive — its return value won't update on layout
  // changes. Instead, we walk the .x chain manually: each property read
  // inside a binding is captured by QML's binding engine, so the binding
  // re-evaluates whenever any chip's or ancestor's x position changes.
  function chipCX(chip) {
    var x = chip.x + chip.width / 2
    var p = chip.parent
    while (p && p !== bar) { x += p.x; p = p.parent }
    return x
  }

  readonly property real networkCX:      chipCX(networkChip)
  readonly property real bluetoothCX:    chipCX(bluetoothChip)
  readonly property real notifCX:        chipCX(notifChip)
  readonly property real volumeCX:       chipCX(volumeChip)
  readonly property real batteryCX:      chipCX(batteryChip)
  readonly property real powerProfileCX: chipCX(powerProfileChip)
  readonly property real brightnessCX:   chipCX(brightnessChip)
  readonly property real clockCX:        chipCX(clockChip)
  readonly property real powerCX:        chipCX(powerChip)
  readonly property real weatherCX:      chipCX(weatherChip)
  readonly property real mediaCX:        chipCX(mediaChip)

  // ── tooltips ──────────────────────────────────────────────────────────
  BarTooltip {
    chipCenterX: bar.networkCX; shown: networkChip.tooltipShown
    text: networkChip.state === "wifi"  ? "WiFi: "  + networkChip.label
        : networkChip.state === "wired" ? "Wired: " + networkChip.label
        : "Not connected"
  }
  BarTooltip {
    chipCenterX: bar.bluetoothCX; shown: bluetoothChip.tooltipShown
    text: !bluetoothChip.powered                  ? "Bluetooth: off"
        : bluetoothChip.connectedCount === 0      ? "Bluetooth: on"
        : bluetoothChip.connectedCount === 1      ? "Bluetooth: " + bluetoothChip.label
                                                  : "Bluetooth: " + bluetoothChip.connectedCount + " devices"
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
    chipCenterX: bar.powerProfileCX; shown: powerProfileChip.tooltipShown
    text: "Profile: " + powerProfileChip.profileName
  }
  BarTooltip {
    chipCenterX: bar.clockCX; shown: clockChip.tooltipShown
    text: Qt.formatDateTime(new Date(), "dddd, MMMM d yyyy")
  }
  BarTooltip {
    chipCenterX: bar.powerCX; shown: powerChip.tooltipShown
    text: "Power menu"
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
  NotificationFlyout { chipCenterX: bar.notifCX; chipWidth: notifChip.width; server: bar.notificationServer }
  NetworkFlyout    { chipCenterX: bar.networkCX;    chipWidth: networkChip.width }
  BluetoothFlyout  { chipCenterX: bar.bluetoothCX;  chipWidth: bluetoothChip.width }
  VolumeFlyout     { chipCenterX: bar.volumeCX;     chipWidth: volumeChip.width }
  BatteryFlyout    { chipCenterX: bar.batteryCX;    chipWidth: batteryChip.width }
  WeatherFlyout    { chipCenterX: bar.weatherCX;    chipWidth: weatherChip.width }
  BrightnessFlyout { chipCenterX: bar.brightnessCX; chipWidth: brightnessChip.width }
  PowerProfileFlyout { chipCenterX: bar.powerProfileCX; chipWidth: powerProfileChip.width }
  PowerMenuFlyout    { chipCenterX: bar.powerCX;        chipWidth: powerChip.width }
  ClockFlyout      { chipCenterX: bar.clockCX;      chipWidth: clockChip.width }
  MediaFlyout      { chipCenterX: bar.mediaCX;      chipWidth: mediaChip.width }
}
