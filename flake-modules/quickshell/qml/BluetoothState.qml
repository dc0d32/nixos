// Singleton: BlueZ state — reads via D-Bus (`busctl
// GetManagedObjects`), writes via a long-lived interactive
// `bluetoothctl` process. Emits reactive properties for the bar
// chip and pairing flyout.
//
// Why this split:
//
//   READ PATH — busctl ObjectManager
//     bluetoothctl in non-interactive mode regressed in BlueZ 5.86:
//     `bluetoothctl show`, `bluetoothctl list`, `bluetoothctl devices`
//     and `bluetoothctl info <mac>` all silently return EMPTY output
//     with exit code 0 unless invoked from an interactive session.
//     That left the chip stuck reading powered=false even with the
//     adapter on. busctl ships with systemd, returns structured JSON
//     with --json=short, and a single ObjectManager.GetManagedObjects
//     call returns the full BlueZ tree (adapter properties + every
//     known device) in one round trip.
//
//   WRITE PATH — long-lived bluetoothctl process
//     Discovery in BlueZ is *session-bound*: the D-Bus client that
//     called StartDiscovery owns the session, and the moment that
//     client disconnects, BlueZ tears the session down. A one-shot
//     `busctl call ... StartDiscovery` returns success, then exits,
//     then the discovery is immediately stopped. The same pattern
//     applies (less obviously) to Connect/Disconnect/Pair, where
//     bluetoothd registers the agent and any pending operations
//     against the calling client. Routing every writeable command
//     through one persistent `bluetoothctl` process means BlueZ sees
//     a single stable client owning all our requests, and the
//     interactive bluetoothctl session also auto-registers an
//     org.bluez.Agent1 for us so PIN/passkey prompts arrive on its
//     stdout (we couldn't implement Agent1 from QML without a C++
//     shim). Setting Powered/Trusted as adapter/device properties
//     would technically work over busctl since they're not session-
//     bound, but routing them through the same agent keeps the
//     mental model "busctl reads, bluetoothctl writes" simple.
//
//   EVENT STREAM — bluetoothctl interactive stdout
//     The same long-lived bluetoothctl process used for writes also
//     emits "[CHG]" / "[NEW]" / "[DEL]" lines on every BlueZ
//     property change, so we use it as our event source too. A
//     debounced ObjectManager re-read fires off those lines. We
//     could replace this with `dbus-monitor --system` or `busctl
//     monitor`, but both require bus-eavesdrop privileges our user
//     lacks on the system bus, whereas bluetoothctl's long-lived
//     bluetoothd connection is already privileged.
//
// Surface:
//   powered      : bool             — controller power state
//   discovering  : bool             — true while a scan is running
//   pairedList   : [{ mac, name, connected, paired, trusted,
//                     battery, icon }]
//   connectedCount : int            — pairedList.filter(d.connected).length
//   pairingMac   : string           — MAC currently in mid-pair (UI lock)
//   pinPromptMac : string           — MAC waiting for a PIN/passkey entry
//   pinPromptText: string           — the prompt itself ("Enter PIN code:")
//   lastError    : string           — last stderr line from a pair attempt
//
// Methods:
//   refreshAll()                    — re-read controller + device tree
//   setPowered(on)                  — power on/off the controller
//   startScan()                     — StartDiscovery
//   stopScan()                      — StopDiscovery
//   pair(mac)                       — fire-and-forget pair attempt (PIN agent)
//   confirmPin(pin)                 — feed PIN to pending pair agent
//   cancelPin()                     — abort the pending pair
//   connectDevice(mac)              — Device1.Connect on already-paired device
//   disconnectDevice(mac)           — Device1.Disconnect
//   removeDevice(mac)               — Adapter1.RemoveDevice (forget)
//   trust(mac)                      — set Device1.Trusted = true
//
// Adapter assumed at /org/bluez/hci0. If we ever ship a host with a
// USB BT dongle on top of an internal adapter, the ObjectManager
// dump will list both and we'd need to pick one (or merge); today
// every host we run on has a single onboard radio.
pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick

QtObject {
  id: root

  // BlueZ object paths. Hardcoded because all our hosts have a
  // single onboard adapter. Multi-adapter handling would mean
  // walking ObjectManager output for every Adapter1 interface.
  readonly property string adapterPath: "/org/bluez/hci0"
  function devicePath(mac) {
    return adapterPath + "/dev_" + mac.replace(/:/g, "_")
  }
  function macFromDevicePath(path) {
    const i = path.lastIndexOf("/dev_")
    if (i < 0) return ""
    return path.substring(i + 5).replace(/_/g, ":")
  }

  // ── controller state ────────────────────────────────────────────
  property bool powered: false
  property bool discovering: false

  // ── device list ─────────────────────────────────────────────────
  // pairedList entries: { mac, name, connected, paired, trusted,
  //                       battery (-1 = unknown), icon }
  property var pairedList: []

  readonly property int connectedCount: {
    let n = 0
    for (const d of pairedList) if (d.connected) n++
    return n
  }

  // ── pairing UX state ────────────────────────────────────────
  property string pairingMac:    ""
  property string pinPromptMac:  ""
  property string pinPromptText: ""
  property string lastError:     ""

  // ── public methods ──────────────────────────────────────────
  function refreshAll() {
    objectManagerProc.running = true
  }

  function setPowered(on) {
    bctl.write((on ? "power on" : "power off") + "\n")
    postCmdTimer.restart()
  }

  function startScan() {
    bctl.write("scan on\n")
    postCmdTimer.restart()
  }

  function stopScan() {
    bctl.write("scan off\n")
    postCmdTimer.restart()
  }

  function pair(mac) {
    root.pairingMac = mac
    root.lastError = ""
    // bluetoothctl auto-registered an org.bluez.Agent1 for us at
    // startup, so PIN prompts will arrive on its stdout.
    bctl.write("pair " + mac + "\n")
  }

  function confirmPin(pin) {
    if (root.pinPromptMac === "") return
    bctl.write(pin + "\n")
    // Some prompts ask for "yes"/"no" confirmation after the PIN is
    // shown on both ends — clear the prompt state and let the next
    // line from the agent re-arm it if needed.
    root.pinPromptMac = ""
    root.pinPromptText = ""
  }

  function cancelPin() {
    if (root.pinPromptMac !== "") {
      bctl.write("cancel\n")
      root.pinPromptMac = ""
      root.pinPromptText = ""
      root.pairingMac = ""
    }
  }

  function connectDevice(mac) {
    bctl.write("connect " + mac + "\n")
    postCmdTimer.restart()
  }
  function disconnectDevice(mac) {
    bctl.write("disconnect " + mac + "\n")
    postCmdTimer.restart()
  }
  function removeDevice(mac) {
    bctl.write("remove " + mac + "\n")
    postCmdTimer.restart()
  }
  function trust(mac) {
    bctl.write("trust " + mac + "\n")
    postCmdTimer.restart()
  }

  // ── ObjectManager poll ──────────────────────────────────────
  // Single busctl call returns the full BlueZ tree as JSON. We
  // parse it once and update both controller state (Adapter1)
  // and the device list (Device1 + optional Battery1) atomically.
  // This replaces what used to be three sequential bluetoothctl
  // invocations (show, devices, then info-per-device).
  property Process _objectManager: Process {
    id: objectManagerProc
    command: ["busctl", "--json=short", "call", "org.bluez", "/",
              "org.freedesktop.DBus.ObjectManager", "GetManagedObjects"]
    running: true
    stdout: StdioCollector { onStreamFinished: {
      let obj = null
      try {
        // busctl --json=short wraps the reply as
        // { type: "a{oa{sa{sv}}}", data: [ <map> ] }
        // The map is path -> { interfaceName -> { propName -> {type, data} } }.
        const parsed = JSON.parse(text)
        obj = parsed && parsed.data && parsed.data[0]
      } catch (e) {
        // Bad JSON — leave state untouched. The next monitor
        // event will retrigger.
        return
      }
      if (!obj) return

      let powered = false, discovering = false
      const devs = {}

      for (const path in obj) {
        const ifaces = obj[path]
        if (path === root.adapterPath && ifaces["org.bluez.Adapter1"]) {
          const ad = ifaces["org.bluez.Adapter1"]
          if (ad.Powered)     powered     = !!ad.Powered.data
          if (ad.Discovering) discovering = !!ad.Discovering.data
        } else if (path.indexOf(root.adapterPath + "/dev_") === 0
                   && ifaces["org.bluez.Device1"]) {
          const dv  = ifaces["org.bluez.Device1"]
          const bat = ifaces["org.bluez.Battery1"]
          const mac = root.macFromDevicePath(path)
          devs[mac] = {
            mac:       mac,
            name:      dv.Alias && dv.Alias.data
                       ? dv.Alias.data
                       : (dv.Name && dv.Name.data ? dv.Name.data : mac),
            connected: !!(dv.Connected && dv.Connected.data),
            paired:    !!(dv.Paired    && dv.Paired.data),
            trusted:   !!(dv.Trusted   && dv.Trusted.data),
            icon:      (dv.Icon && dv.Icon.data) || "",
            battery:   (bat && bat.Percentage && typeof bat.Percentage.data === "number")
                       ? bat.Percentage.data : -1
          }
        }
      }

      root.powered     = powered
      root.discovering = discovering

      // Sort: connected first, then paired, then by name.
      const arr = []
      for (const mac in devs) arr.push(devs[mac])
      arr.sort((a, b) => {
        if (a.connected !== b.connected) return a.connected ? -1 : 1
        if (a.paired    !== b.paired)    return a.paired    ? -1 : 1
        return a.name.localeCompare(b.name)
      })
      root.pairedList = arr
    }}
  }

  // ── pairing agent (interactive bluetoothctl) ────────────────────
  // Long-lived bluetoothctl process. All writeable commands
  // (power, scan, connect, disconnect, pair, remove, trust) are
  // sent here as text on stdin. BlueZ treats this single client as
  // the owner of every operation, which matters for discovery
  // (session-bound, dies the moment a one-shot client disconnects)
  // and for pairing (the org.bluez.Agent1 bluetoothctl auto-
  // registers receives PIN/passkey prompts for us). Prompts
  // arrive on stdout (e.g. "[agent] Enter PIN code:" or
  // "[agent] Confirm passkey 123456 (yes/no):") and we write the
  // user's response back via `bctl.write(...)`. We also use this
  // process's stdout as the property-change event source: every
  // BlueZ change comes through as a "[CHG] ..." line that triggers
  // a debounced ObjectManager re-read. Keeps us to a single
  // bluetoothctl child instead of having a separate `--monitor`.
  // Agent1 re-implementation in pure QML would require exporting a
  // D-Bus object, which Quickshell can't do without a custom C++
  // shim.
  property Process _bctl: Process {
    id: bctl
    command: ["bluetoothctl"]
    running: true
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: data => {
        if (!data) return
        // Strip ANSI escapes that bluetoothctl emits in interactive mode.
        const line = data.replace(/\x1b\[[0-9;]*[A-Za-z]/g, "").trim()

        // Every property change emits a "[CHG]" line - cheaper than
        // running a separate `bluetoothctl --monitor`.
        if (line.indexOf("[CHG]") >= 0
            || line.indexOf("[NEW]") >= 0
            || line.indexOf("[DEL]") >= 0
            || line.indexOf("Discovery started") >= 0
            || line.indexOf("Discovery stopped") >= 0) {
          debounce.restart()
          // fall through - some [CHG] lines are also pair feedback
        }
        // PIN / passkey prompts. The "[agent] " prefix is reliable
        // across BlueZ ≥ 5.50.
        const promptMatch = line.match(/\[agent\]\s+(.+?)\s+\(([0-9A-F:]{17})\)/i)
        if (promptMatch) {
          root.pinPromptMac  = promptMatch[2]
          root.pinPromptText = promptMatch[1]
          return
        }
        // Some prompts include the MAC inline differently or omit it;
        // fall back to using root.pairingMac.
        if (line.indexOf("[agent] ") === 0) {
          root.pinPromptMac  = root.pairingMac
          root.pinPromptText = line.substring(8)
          return
        }

        // Pair completion / failure messages.
        if (line.indexOf("Pairing successful") >= 0) {
          const justPaired = root.pairingMac
          root.pairingMac = ""
          root.pinPromptMac = ""
          root.pinPromptText = ""
          // After a successful pair we usually want to trust the
          // device so later reconnects are silent. bluetoothctl
          // auto-trusts in many BlueZ builds, but we set it
          // explicitly to be sure.
          if (justPaired !== "") root.trust(justPaired)
          debounce.restart()
        } else if (line.indexOf("Failed to pair") >= 0
                   || line.indexOf("AuthenticationFailed") >= 0
                   || line.indexOf("AuthenticationCanceled") >= 0
                   || line.indexOf("AuthenticationRejected") >= 0) {
          root.lastError = line
          root.pairingMac = ""
          root.pinPromptMac = ""
          root.pinPromptText = ""
        }
      }
    }
  }

  property Timer _debounce: Timer {
    id: debounce
    interval: 250; repeat: false
    onTriggered: root.refreshAll()
  }

  // After a fire-and-forget command (power, scan, connect, …) a
  // [CHG] line will normally fire on bctl — but a guaranteed
  // re-read 1.0s later catches the edge case where the command
  // failed silently with no resulting state change.
  property Timer _postCmd: Timer {
    id: postCmdTimer
    interval: 1000; repeat: false
    onTriggered: root.refreshAll()
  }
}
