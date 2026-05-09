// Top bar: [Workspaces] | [ActiveWindow] | [Tray | Media | Weather] | [Notifs | Net | Vol | Brightness | Clock]
//
// This file declares THREE classes of PanelWindows that together make
// up "the bar" experience:
//
//   1. `bar` (namespace "quickshell-bar")
//        Small layer surface anchored to the top of the screen, exactly
//        Theme.barHeight + 2 px tall — the size of the visible chip strip.
//        Holds the chip RowLayout. Opts in to niri's catch-all
//        background-effect blur, giving the chip strip a frosted-glass
//        look. Because the surface is exactly the height of the strip,
//        niri's per-surface blur has nothing extra to render — no blurred
//        band hangs below the strip.
//
//   2. `flyoutCanvas` (namespace "quickshell-flyouts")
//        Full-screen layer surface, mapped while ANY flyout OR tooltip is
//        shown. Hosts:
//          - The dismiss-on-outside-click MouseArea (only enabled when a
//            flyout is open; tooltips are passive)
//          - All BarTooltip popups (positioned by chip center X published
//            by `bar`; coordinate spaces match because both windows share
//            the same 2-px gutter margins)
//        niri excludes this namespace from the catch-all blur (the
//        dismiss / passthrough region must stay clear, and tooltip cards
//        already have an opaque-enough Theme.surface0 background).
//
//   3. Per-flyout PanelWindows (namespace "quickshell-flyout-<name>")
//        One PanelWindow per flyout (volume, brightness, etc.), each via
//        the FlyoutWindow.qml wrapper. Sized to its own bounding box and
//        positioned over its originating chip. Mapped only while that
//        flyout is the active one. niri opts these surfaces into the
//        catch-all blur (they don't match the "^quickshell-flyouts$"
//        exclusion regex), giving each card its own per-surface
//        live-composite frosted-glass backdrop.
//
// Click routing during an open flyout:
//   - A click inside the flyout's PanelWindow surface (its bounding box)
//     hits whichever MouseArea is on the card at that point. Layer
//     surfaces in the same layer are stacked by creation order, and the
//     per-flyout surface is created lazily after the canvas, so it
//     intercepts first.
//   - A click outside the flyout's surface bounds passes to the
//     full-screen canvas underneath, which fires its dismiss MouseArea.
//
// Input mask of the canvas:
//   - Flyout open: dismissArea region (entire surface receives input).
//   - Tooltip only: empty mask (Region item: null) — clicks/hover pass
//     through to windows underneath. Tooltips are visual-only.
//   - Nothing shown: PanelWindow `visible: false` → surface unmapped.
//
// History: previously a single tall PanelWindow (~460 px) hosted both
// chips and flyouts as plain QML Items. niri blurs the entire layer-
// surface rectangle, not just painted-alpha pixels, so a unified bar
// surface produced a visible blurred-wallpaper strip across the whole
// screen even when no flyout was open. That forced niri.nix to exclude
// the bar from blur entirely. The split here lets each surface be
// exactly its visible bounds — the chip strip is glassy, each flyout
// card is glassy, and nothing else is.
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Layouts

import ".."

Scope {
  id: barScope

  // Forwarded to both PanelWindows so they live on the same output.
  // shell.qml instantiates one Bar per screen via Variants.
  property var screen: null
  property NotificationServer notificationServer

  readonly property bool flyoutOpen: FlyoutManager.active !== ""

  // Aggregate of every chip's tooltipShown. Used to map the flyout
  // canvas while a tooltip is visible (so the tooltip card can render
  // there). Recomputed automatically by QML's binding engine whenever
  // any chip's tooltipShown changes.
  readonly property bool anyTooltipShown:
       networkChip.tooltipShown
    || bluetoothChip.tooltipShown
    || volumeChip.tooltipShown
    || (batteryChip.tooltipShown && batteryChip.present)
    || brightnessChip.tooltipShown
    || powerProfileChip.tooltipShown
    || clockChip.tooltipShown
    || powerChip.tooltipShown
    || weatherChip.tooltipShown
    || mediaChip.tooltipShown

  // ── chip-strip surface ────────────────────────────────────────────────
  PanelWindow {
    id: bar

    screen: barScope.screen
    anchors { top: true; left: true; right: true }
    margins  { top: 2; left: 2; right: 2 }

    implicitHeight: Theme.barHeight + 2
    color: "transparent"
    WlrLayershell.namespace: "quickshell-bar"
    WlrLayershell.layer: WlrLayershell.Top
    WlrLayershell.exclusiveZone: Theme.barHeight + 2

    // ── bar strip background ────────────────────────────────────────────
    Rectangle {
      x: 0; y: 0; width: parent.width; height: Theme.barHeight
      radius: Theme.radius; color: Theme.base; opacity: Theme.opacity
      border.color: Theme.surface1; border.width: 1
    }

    // ── bar content ─────────────────────────────────────────────────────
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
          NotificationChip { id: notifChip; server: barScope.notificationServer }
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
  }

  // ── flyout canvas surface ───────────────────────────────────────────────
  // Full-screen layer surface that hosts flyout cards, BarTooltip popups,
  // and a click-to-dismiss MouseArea. Mapped only while at least one of
  // them is showing so at rest there is no additional layer surface and
  // no compositor cost.
  //
  // Margins match the chip-strip window (top:2; left:2; right:2) and the
  // canvas anchors top+left+right+bottom, so chip-center X coordinates
  // published by `bar` work here without offset adjustment.
  PanelWindow {
    id: flyoutCanvas

    screen: barScope.screen
    anchors { top: true; left: true; right: true; bottom: true }
    margins  { top: 2; left: 2; right: 2; bottom: 2 }

    visible: barScope.flyoutOpen || barScope.anyTooltipShown
    color: "transparent"
    WlrLayershell.namespace: "quickshell-flyouts"
    WlrLayershell.layer: WlrLayershell.Top
    WlrLayershell.exclusiveZone: 0

    // Input mask:
    //   - flyoutOpen: full-canvas region (the dismiss MouseArea below
    //     receives outside-card clicks).
    //   - tooltip only: null region — entire surface is click-through;
    //     hover/click reaches the windows underneath. Tooltip cards
    //     are purely visual.
    mask: Region { item: barScope.flyoutOpen ? dismissArea : null }

    // ── dismiss backdrop ────────────────────────────────────────────────
    // Disabled while only a tooltip is shown: tooltips don't dismiss on
    // click, and the input mask above is null in that state anyway.
    MouseArea {
      id: dismissArea
      anchors.fill: parent
      enabled: barScope.flyoutOpen
      onClicked: FlyoutManager.close()
    }

    // ── tooltips ────────────────────────────────────────────────────────
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
  }

  // ── per-flyout PanelWindows ────────────────────────────────────────────
  // Each flyout is its own Wayland layer surface (namespace
  // "quickshell-flyout-<name>") so niri's per-surface blur extends only
  // over the card's bounding box — not the full screen behind it. The
  // FlyoutWindow wrapper handles namespace/visibility/positioning; the
  // flyout's own QML defines the card.
  //
  // Stacking: per-flyout surfaces are created lazily after `flyoutCanvas`,
  // so within the Top layer they sit above it. Clicks inside the card's
  // bounding box are intercepted by the card's PanelWindow; clicks
  // outside fall through to the canvas's dismiss MouseArea below.
  NotificationFlyout { screen: barScope.screen; chipCenterX: bar.notifCX;        chipWidth: notifChip.width;        server: barScope.notificationServer }
  BluetoothFlyout    { screen: barScope.screen; chipCenterX: bar.bluetoothCX;    chipWidth: bluetoothChip.width }
  VolumeFlyout       { screen: barScope.screen; chipCenterX: bar.volumeCX;       chipWidth: volumeChip.width }
  BatteryFlyout      { screen: barScope.screen; chipCenterX: bar.batteryCX;      chipWidth: batteryChip.width }
  WeatherFlyout      { screen: barScope.screen; chipCenterX: bar.weatherCX;      chipWidth: weatherChip.width }
  BrightnessFlyout   { screen: barScope.screen; chipCenterX: bar.brightnessCX;   chipWidth: brightnessChip.width }
  PowerProfileFlyout { screen: barScope.screen; chipCenterX: bar.powerProfileCX; chipWidth: powerProfileChip.width }
  PowerMenuFlyout    { screen: barScope.screen; chipCenterX: bar.powerCX;        chipWidth: powerChip.width }
  ClockFlyout        { screen: barScope.screen; chipCenterX: bar.clockCX;        chipWidth: clockChip.width }
  MediaFlyout        { screen: barScope.screen; chipCenterX: bar.mediaCX;        chipWidth: mediaChip.width }
}
