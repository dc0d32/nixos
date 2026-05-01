// Singleton: BlueZ state via `bluetoothctl`. Parallel to NetworkState
// but for Bluetooth: pairs a long-running `bluetoothctl --monitor` event
// stream with debounced one-shot reads of the controller and device
// lists. Emits reactive properties for the bar chip and pairing flyout.
//
// Why bluetoothctl (not D-Bus directly):
//   Quickshell.Io exposes Process / SplitParser cleanly; binding QML
//   to BlueZ's org.bluez.* D-Bus tree would require either a Qt-side
//   QDBus wrapper module (not available in vanilla Quickshell) or a
//   long-running shell helper that introspects D-Bus. bluetoothctl
//   already does the introspection and ships in the bluez package
//   we install at the system level (flake-modules/bluetooth.nix).
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
//   refreshAll()                    — re-read controller + device lists
//   setPowered(on)                  — power on/off the controller
//   startScan()                     — `bluetoothctl scan on`
//   stopScan()                      — `bluetoothctl scan off`
//   pair(mac)                       — fire-and-forget pair attempt
//   confirmPin(pin)                 — feed PIN to pending pair agent
//   cancelPin()                     — abort the pending pair
//   connectDevice(mac)              — connect to an already-paired device
//   disconnectDevice(mac)           — disconnect a connected device
//   removeDevice(mac)               — unpair / forget a device
//   trust(mac)                      — set trusted=yes (auto-reconnect later)
//
// PIN/passkey flow: bluetoothctl runs a built-in agent by default, but
// to receive PIN prompts we spawn an interactive `bluetoothctl` with
// stdin connected to a Process and parse its prompts out of stdout.
// See pairAgent below.
pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick

QtObject {
  id: root

  // ── controller state ────────────────────────────────────────────────
  property bool powered: false
  property bool discovering: false

  // ── device list ─────────────────────────────────────────────────────
  // pairedList entries: { mac, name, connected, paired, trusted,
  //                       battery (-1 = unknown), icon }
  property var pairedList: []

  readonly property int connectedCount: {
    let n = 0
    for (const d of pairedList) if (d.connected) n++
    return n
  }

  // ── pairing UX state ────────────────────────────────────────────────
  property string pairingMac:    ""
  property string pinPromptMac:  ""
  property string pinPromptText: ""
  property string lastError:     ""

  // ── public methods ──────────────────────────────────────────────────
  function refreshAll() {
    showPoller.running = true
    devicesPoller.running = true
  }

  function setPowered(on) {
    Quickshell.execDetached(["bluetoothctl", "power", on ? "on" : "off"])
    postCmdTimer.restart()
  }

  function startScan() {
    Quickshell.execDetached(["bluetoothctl", "--timeout", "30", "scan", "on"])
    postCmdTimer.restart()
  }

  function stopScan() {
    Quickshell.execDetached(["bluetoothctl", "scan", "off"])
    postCmdTimer.restart()
  }

  function pair(mac) {
    root.pairingMac = mac
    root.lastError = ""
    // Run pair via the interactive agent so PIN prompts are captured.
    pairAgent.write("pair " + mac + "\n")
  }

  function confirmPin(pin) {
    if (root.pinPromptMac === "") return
    pairAgent.write(pin + "\n")
    // Some prompts ask for "yes"/"no" confirmation after the PIN is
    // shown on both ends — clear the prompt state and let the next
    // line from the agent re-arm it if needed.
    root.pinPromptMac = ""
    root.pinPromptText = ""
  }

  function cancelPin() {
    if (root.pinPromptMac !== "") {
      pairAgent.write("cancel\n")
      root.pinPromptMac = ""
      root.pinPromptText = ""
      root.pairingMac = ""
    }
  }

  function connectDevice(mac)    { Quickshell.execDetached(["bluetoothctl", "connect", mac]); postCmdTimer.restart() }
  function disconnectDevice(mac) { Quickshell.execDetached(["bluetoothctl", "disconnect", mac]); postCmdTimer.restart() }
  function removeDevice(mac)     { Quickshell.execDetached(["bluetoothctl", "remove", mac]); postCmdTimer.restart() }
  function trust(mac)            { Quickshell.execDetached(["bluetoothctl", "trust", mac]); postCmdTimer.restart() }

  // ── pollers ─────────────────────────────────────────────────────────
  // Controller state via `bluetoothctl show`. Output looks like:
  //   Controller AA:BB:CC:DD:EE:FF (public)
  //         Powered: yes
  //         Discovering: no
  //         …
  property Process _showPoller: Process {
    id: showPoller
    command: ["bluetoothctl", "show"]
    running: true
    stdout: StdioCollector { onStreamFinished: {
      let powered = false, discovering = false
      for (const raw of text.split("\n")) {
        const line = raw.trim()
        if (line.startsWith("Powered:"))     powered     = line.endsWith("yes")
        if (line.startsWith("Discovering:")) discovering = line.endsWith("yes")
      }
      root.powered     = powered
      root.discovering = discovering
    }}
  }

  // Combined paired+visible device list. We get the MAC/name set from
  // `bluetoothctl devices` (all known to the daemon — paired and any
  // currently-discovered ones during a scan) and per-device details
  // via a chained `info` walk. Output of `devices` looks like:
  //   Device AA:BB:CC:DD:EE:FF Sony WH-1000XM4
  property Process _devicesPoller: Process {
    id: devicesPoller
    command: ["bluetoothctl", "devices"]
    running: true
    stdout: StdioCollector { onStreamFinished: {
      const macs = []
      const stub = {}
      for (const line of text.split("\n")) {
        if (!line.startsWith("Device ")) continue
        const sp1 = line.indexOf(" ", 7)
        if (sp1 < 0) continue
        const mac = line.substring(7, sp1)
        const name = line.substring(sp1 + 1).trim()
        macs.push(mac)
        stub[mac] = { mac, name,
                      connected: false, paired: false, trusted: false,
                      battery: -1, icon: "" }
      }
      // Walk each MAC sequentially with `bluetoothctl info <mac>`. The
      // accumulator below updates pairedList incrementally; UI
      // re-renders as each device's info comes back.
      root.pairedList = macs.map(m => stub[m])
      infoWalker.queue = macs.slice()
      infoWalker.acc = stub
      infoWalker.next()
    }}
  }

  // Sequential `bluetoothctl info <mac>` walker. Re-enters itself on
  // each StdioCollector.onStreamFinished until the queue is empty,
  // then assigns root.pairedList one final time so any late-arriving
  // properties (battery percentage) propagate to the UI.
  property var _infoWalker: QtObject {
    id: infoWalker
    property var queue: []
    property var acc:   ({})
    property string current: ""

    function next() {
      if (queue.length === 0) {
        // Final assignment after all info reads complete; the
        // intermediate per-device updates above already drove most of
        // the UI, but rebuilding the array here guarantees QML
        // notices any property the StdioCollector mutated in place.
        const arr = []
        for (const mac in acc) arr.push(acc[mac])
        // Sort: connected first, then paired, then by name.
        arr.sort((a, b) => {
          if (a.connected !== b.connected) return a.connected ? -1 : 1
          if (a.paired    !== b.paired)    return a.paired    ? -1 : 1
          return a.name.localeCompare(b.name)
        })
        root.pairedList = arr
        return
      }
      current = queue.shift()
      infoProc.command = ["bluetoothctl", "info", current]
      infoProc.running = true
    }
  }
  property Process _infoProc: Process {
    id: infoProc
    command: ["bluetoothctl", "info"]   // overwritten by walker.next()
    running: false
    stdout: StdioCollector { onStreamFinished: {
      const mac = infoWalker.current
      const dev = infoWalker.acc[mac]
      if (dev) {
        for (const raw of text.split("\n")) {
          const line = raw.trim()
          if (line.startsWith("Connected:"))   dev.connected = line.endsWith("yes")
          else if (line.startsWith("Paired:")) dev.paired    = line.endsWith("yes")
          else if (line.startsWith("Trusted:"))dev.trusted   = line.endsWith("yes")
          else if (line.startsWith("Icon:"))   dev.icon      = line.substring(5).trim()
          else if (line.startsWith("Battery Percentage:")) {
            // Format: "Battery Percentage: 0x53 (83)"  — pull the decimal.
            const m = line.match(/\((\d+)\)/)
            if (m) dev.battery = parseInt(m[1])
          }
          else if (line.startsWith("Name:") && !dev.name) {
            dev.name = line.substring(5).trim()
          }
        }
      }
      infoWalker.next()
    }}
  }

  // ── pairing agent (interactive bluetoothctl) ────────────────────────
  // Long-lived bluetoothctl process for PIN-required pairings. Prompts
  // arrive on stdout (e.g. "[agent] Enter PIN code:" or
  // "[agent] Confirm passkey 123456 (yes/no):") and we write the
  // user's response back over stdin via `pairAgent.write(...)`.
  property Process _pairAgent: Process {
    id: pairAgent
    command: ["bluetoothctl"]
    running: true
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: data => {
        if (!data) return
        // Strip ANSI escapes that bluetoothctl emits in interactive mode.
        const line = data.replace(/\x1b\[[0-9;]*[A-Za-z]/g, "").trim()

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
          root.pairingMac = ""
          root.pinPromptMac = ""
          root.pinPromptText = ""
          // After a successful pair we usually want to trust + connect.
          // bluetoothctl auto-trusts in many BlueZ builds, but we set
          // it explicitly to ensure later reconnects are silent.
          if (root.pairingMac !== "") root.trust(root.pairingMac)
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

  // ── event source: bluetoothctl --monitor ────────────────────────────
  // Long-running monitor; fires on every BlueZ property change. Debounced
  // to coalesce bursts (e.g. a fresh connect emits Connected, ServicesResolved,
  // Paired, Trusted, Battery in rapid succession).
  property Process _monitor: Process {
    command: ["bluetoothctl", "--monitor"]
    running: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: data => { if (data) debounce.restart() }
    }
  }
  property Timer _debounce: Timer {
    id: debounce
    interval: 250; repeat: false
    onTriggered: root.refreshAll()
  }

  // After a fire-and-forget command (power, scan, connect, …) the
  // monitor will fire — but a guaranteed re-read 1.0s later catches
  // the edge case where the command failed silently.
  property Timer _postCmd: Timer {
    id: postCmdTimer
    interval: 1000; repeat: false
    onTriggered: root.refreshAll()
  }
}
