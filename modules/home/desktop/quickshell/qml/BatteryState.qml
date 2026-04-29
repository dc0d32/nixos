// Singleton: thin event-driven wrapper around Quickshell.Services.UPower.
// Replaces the previous per-widget `sh -c "cat /sys/class/power_supply/BAT*/..."`
// pollers in Battery.qml and BatteryFlyout.qml that fired every 10s.
//
// Surface:
//   present    : bool      — true iff a laptop battery exists
//   percent    : int       — 0..100, rounded
//   charging   : bool      — UPowerDeviceState.Charging
//   status     : string    — "Charging" | "Discharging" | "Full" | "Unknown"
//   timeLeft   : string    — humanised "1h 23m" / "45m" or "" if not estimable
//
// Note: UPower.displayDevice always exists (never null) but may be unready
// pre-init; we additionally check `isLaptopBattery` to hide the chip on
// desktops / hosts without a battery.
pragma Singleton

import Quickshell
import Quickshell.Services.UPower
import QtQuick

QtObject {
  id: root

  readonly property var _dev: UPower.displayDevice

  readonly property bool present:
    _dev && _dev.ready && _dev.isLaptopBattery && _dev.isPresent

  readonly property int percent:
    // quickshell's UPowerDevice.percentage is 0.0–1.0 (energy / capacity),
    // not 0–100 like the dbus org.freedesktop.UPower.Device.Percentage
    // property it wraps. Multiply before rounding or 0.95 collapses to 1.
    present ? Math.round(_dev.percentage * 100) : 0

  readonly property bool charging:
    present && _dev.state === UPowerDeviceState.Charging

  readonly property string status:
    !present                                              ? "Unknown"
  : _dev.state === UPowerDeviceState.Charging             ? "Charging"
  : _dev.state === UPowerDeviceState.Discharging          ? "Discharging"
  : _dev.state === UPowerDeviceState.FullyCharged         ? "Full"
  : "Unknown"

  // Time remaining/until-full in seconds (UPower units).
  readonly property real _seconds:
    !present ? 0
  : charging ? (_dev.timeToFull  || 0)
  :            (_dev.timeToEmpty || 0)

  readonly property string timeLeft: {
    const s = _seconds
    if (s <= 0) return ""
    const totalMin = Math.round(s / 60)
    const h = Math.floor(totalMin / 60)
    const m = totalMin % 60
    return h > 0 ? (h + "h " + m + "m") : (m + "m")
  }
}
