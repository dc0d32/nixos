// Top bar: [Workspaces] | [ActiveWindow] | [Tray | Media | Weather] | [Notifs | Net | Vol | Brightness | Clock]
//
// This file declares FOUR classes of PanelWindows that together make
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
//        Full-screen layer surface, mapped only while a flyout is open.
//        Hosts the dismiss-on-outside-click MouseArea. niri excludes
//        this namespace from the catch-all blur (the dismiss /
//        passthrough region must stay clear; the visible flyout cards
//        live in their own per-flyout surfaces).
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
//   4. Per-tooltip PanelWindows (namespace "quickshell-tooltip-<id>")
//        One PanelWindow per chip tooltip, via the BarTooltip.qml
//        wrapper. Same anchoring scheme as FlyoutWindow so vertical
//        placement matches the per-flyout panels (flush with the bar's
//        visible bottom). Mapped only while the chip is hovered AND no
//        flyout is open. Uses its own namespace so they pick up the
//        catch-all blur (frosted-glass cards) without matching the
//        flyout-canvas exclusion.
//
// Click routing during an open flyout:
//   - niri stacks layer surfaces within the same layer by MAP order.
//     The dismiss canvas is mapped lazily on first flyout open and
//     stays mapped after; per-flyout surfaces are also mapped lazily.
//     Confirmed via `niri msg layers`: bar < flyout-<name> < flyouts
//     (canvas) bottom-to-top — i.e. the canvas always wins z-order.
//   - To prevent the canvas from eating clicks meant for the per-flyout
//     surface beneath it, the canvas's input mask is "full canvas region
//     MINUS active flyout's screen rect". Each FlyoutWindow publishes
//     its rect into FlyoutManager.activeX/Y/W/H on visibility; this
//     scope subtracts it via Region.intersection: Subtract.
//   - Clicks INSIDE the cutout fall through Wayland's input region
//     check on the canvas → land on the per-flyout surface beneath.
//   - Clicks OUTSIDE the cutout hit the canvas's dismiss MouseArea.
//
// History: previously a single tall PanelWindow (~460 px) hosted both
// chips and flyouts as plain QML Items. niri blurs the entire layer-
// surface rectangle, not just painted-alpha pixels, so a unified bar
// surface produced a visible blurred-wallpaper strip across the whole
// screen even when no flyout was open. That forced niri.nix to exclude
// the bar from blur entirely. The split here lets each surface be
// exactly its visible bounds — the chip strip is glassy, each flyout
// card is glassy, each tooltip card is glassy, and nothing else is.
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
  // Full-screen layer surface that hosts the click-to-dismiss
  // MouseArea while a flyout is open. Mapped only while a flyout is
  // open so at rest there is no additional layer surface and no
  // compositor cost.
  //
  // Margins match the chip-strip window (top:2; left:2; right:2).
  PanelWindow {
    id: flyoutCanvas

    screen: barScope.screen
    anchors { top: true; left: true; right: true; bottom: true }
    margins  { top: 2; left: 2; right: 2; bottom: 2 }

    visible: barScope.flyoutOpen
    color: "transparent"
    WlrLayershell.namespace: "quickshell-flyouts"
    WlrLayershell.layer: WlrLayershell.Top
    WlrLayershell.exclusiveZone: 0

    // Input mask: full-canvas region MINUS the active flyout's screen
    // rect (translated into canvas-local coords). Outside-card clicks
    // hit the dismiss MouseArea; clicks INSIDE the cutout fall through
    // this surface to the per-flyout layer surface beneath it. The
    // cutout is necessary because niri stacks layer surfaces by map
    // order and this canvas tends to be mapped after the per-flyout
    // surfaces (so it's on TOP), so without a cutout the canvas would
    // eat every click meant for the flyout.
    mask: Region {
      item: barScope.flyoutOpen ? dismissArea : null
      Region {
        // Canvas-local coords = screen coords minus this canvas's
        // top-left corner. Top-left in screen coords is (gutter,
        // barExclusionZone + gutter) = (2, 36) at default values, but
        // bind dynamically so both surfaces stay in sync if someone
        // tweaks gutter/barHeight.
        x: barScope.flyoutOpen ? Math.round(FlyoutManager.activeX - 2) : 0
        y: barScope.flyoutOpen
            ? Math.round(FlyoutManager.activeY - (Theme.barHeight + 4))
            : 0
        width:  barScope.flyoutOpen ? Math.round(FlyoutManager.activeW) : 0
        height: barScope.flyoutOpen ? Math.round(FlyoutManager.activeH) : 0
        intersection: Intersection.Subtract
      }
    }

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
    // Tooltips are their own per-tooltip PanelWindows (siblings of
    // the per-flyout surfaces below) — see BarTooltip.qml header for
    // why. Nothing rendered here.
  }

  // ── per-tooltip PanelWindows ───────────────────────────────────────────
  // Each tooltip is its own Wayland layer surface (namespace
  // "quickshell-tooltip-<id>"), positioned over its originating chip
  // with the same anchoring scheme as FlyoutWindow so vertical
  // placement is identical to the per-flyout panels (flush with the
  // bar's visible bottom). Mapped only while the chip is hovered.
  BarTooltip {
    screen: barScope.screen; tooltipId: "network"
    chipCenterX: bar.networkCX; shown: networkChip.tooltipShown
    text: NetworkState.currentState === "wifi"  ? "WiFi: "  + networkChip.label
        : NetworkState.currentState === "wired" ? "Wired: " + networkChip.label
        : "Not connected"
  }
  BarTooltip {
    screen: barScope.screen; tooltipId: "bluetooth"
    chipCenterX: bar.bluetoothCX; shown: bluetoothChip.tooltipShown
    text: !bluetoothChip.powered                  ? "Bluetooth: off"
        : bluetoothChip.connectedCount === 0      ? "Bluetooth: on"
        : bluetoothChip.connectedCount === 1      ? "Bluetooth: " + bluetoothChip.label
                                                  : "Bluetooth: " + bluetoothChip.connectedCount + " devices"
  }
  BarTooltip {
    screen: barScope.screen; tooltipId: "volume"
    chipCenterX: bar.volumeCX; shown: volumeChip.tooltipShown
    text: VolumeState.muted ? "Muted" : "Volume: " + VolumeState.volume + "%"
  }
  BarTooltip {
    screen: barScope.screen; tooltipId: "battery"
    chipCenterX: bar.batteryCX; shown: batteryChip.tooltipShown && BatteryState.present
    text: "Battery: " + BatteryState.percent + "% — " + BatteryState.status
  }
  BarTooltip {
    screen: barScope.screen; tooltipId: "brightness"
    chipCenterX: bar.brightnessCX; shown: brightnessChip.tooltipShown
    text: "Brightness: " + BrightnessState.percent + "%"
  }
  BarTooltip {
    screen: barScope.screen; tooltipId: "powerprofile"
    chipCenterX: bar.powerProfileCX; shown: powerProfileChip.tooltipShown
    text: "Profile: " + powerProfileChip.profileName
  }
  BarTooltip {
    screen: barScope.screen; tooltipId: "clock"
    chipCenterX: bar.clockCX; shown: clockChip.tooltipShown
    text: Qt.formatDateTime(new Date(), "dddd, MMMM d yyyy")
  }
  BarTooltip {
    screen: barScope.screen; tooltipId: "power"
    chipCenterX: bar.powerCX; shown: powerChip.tooltipShown
    text: "Power menu"
  }
  BarTooltip {
    screen: barScope.screen; tooltipId: "weather"
    chipCenterX: bar.weatherCX; shown: weatherChip.tooltipShown
    text: WeatherModel.location !== ""
        ? WeatherModel.location + ": " + WeatherModel.conditionText + ", " + WeatherModel.temp
        : WeatherModel.conditionText + ", " + WeatherModel.temp
  }
  BarTooltip {
    screen: barScope.screen; tooltipId: "media"
    chipCenterX: bar.mediaCX; shown: mediaChip.tooltipShown
    text: mediaChip.player ? (mediaChip.player.trackTitle + " · " + mediaChip.player.trackArtist) : ""
  }

  // ── per-flyout PanelWindows ────────────────────────────────────────────
  // Each flyout is its own Wayland layer surface (namespace
  // "quickshell-flyout-<name>") so niri's per-surface blur extends only
  // over the card's bounding box — not the full screen behind it. The
  // FlyoutWindow wrapper handles namespace/visibility/positioning; the
  // flyout's own QML defines the card.
  //
  // Stacking (verified via `niri msg layers`): the dismiss canvas
  // `flyoutCanvas` is mapped at startup and stays mapped, while these
  // per-flyout surfaces map lazily on first show. Within niri's Top
  // layer, surfaces are stacked by map order, so the canvas always sits
  // ABOVE these surfaces — which would normally let it eat all clicks.
  // The canvas's input mask compensates by subtracting the active
  // flyout's screen rect (see header note + canvas's mask: Region).
  // Clicks inside the cutout fall through Wayland's input region check
  // on the canvas to land here; clicks outside hit the dismiss
  // MouseArea on the canvas.
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
