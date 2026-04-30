// Singleton: NetworkManager state. Replaces the per-widget 5s polling
// Timer with a long-running `nmcli monitor` event-stream that pushes
// changes immediately, plus a debounced `nmcli device wifi list` rescan.
//
// Surface:
//   currentSsid  : string  — connection name (Wi-Fi SSID or wired profile)
//   currentState : string  — "wifi" | "wired" | "off"
//   currentIface : string  — kernel interface name (for nmcli disconnect)
//   apList       : [{ ssid, signal, secured, inUse }]   sorted by signal
//
// Methods:
//   refreshStatus()    — re-read connection state once
//   refreshAps()       — re-scan Wi-Fi access-point list once
//   tryConnect(ssid)            — open / saved connection
//   connectWithPassword(s, p)   — fresh password
//   disconnect()                — disconnect current iface
pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick

QtObject {
  id: root

  property string currentSsid:  ""
  property string currentState: "off"
  property string currentIface: ""
  property var    apList:       []

  function refreshStatus() { statusPoller.running = true }
  function refreshAps()    { apScanner.running    = true }

  function tryConnect(ssid) {
    Quickshell.execDetached(["nmcli", "device", "wifi", "connect", ssid])
    postConnectTimer.restart()
  }

  function connectWithPassword(ssid, pwd) {
    Quickshell.execDetached(["nmcli", "device", "wifi", "connect", ssid, "password", pwd])
    postConnectTimer.restart()
  }

  function disconnect() {
    if (currentIface === "") return
    Quickshell.execDetached(["nmcli", "device", "disconnect", currentIface])
    postConnectTimer.restart()
  }

  // ── pollers (one-shot, kicked by refresh*/monitor) ──────────────────
  property Process _statusPoller: Process {
    id: statusPoller
    command: ["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION,DEVICE", "device"]
    running: true
    stdout: StdioCollector { onStreamFinished: {
      let ssid = "", state = "off", iface = ""
      for (const line of text.split("\n")) {
        if (!line) continue
        const [type, st, conn, dev] = line.split(":")
        if (st !== "connected") continue
        if (type === "wifi")     { ssid = conn; state = "wifi";  iface = dev; break }
        if (type === "ethernet") { ssid = conn; state = "wired"; iface = dev }
      }
      root.currentSsid  = ssid
      root.currentState = state
      root.currentIface = iface
    }}
  }

  property Process _apScanner: Process {
    id: apScanner
    command: ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list"]
    running: true
    stdout: StdioCollector { onStreamFinished: {
      const seen = new Set(), list = []
      for (const line of text.split("\n")) {
        if (!line) continue
        const idx = line.indexOf(":"); if (idx < 0) continue
        const inUse = line.substring(0, idx).trim() === "*"
        const parts = line.substring(idx + 1).split(":")
        if (parts.length < 3) continue
        const ssid    = parts[0]
        const signal  = parseInt(parts[1]) || 0
        const secured = (parts.slice(2).join(":").trim() || "--") !== "--"
        if (!ssid || seen.has(ssid)) continue
        seen.add(ssid); list.push({ ssid, signal, secured, inUse })
      }
      list.sort((a, b) => b.signal - a.signal)
      root.apList = list
    }}
  }

  // ── event source: long-running `nmcli monitor` ──────────────────────
  // Emits a one-line summary every time NM state changes (connect /
  // disconnect / scan-completed / device added). We debounce to coalesce
  // bursts during a connection handshake.
  property Process _monitor: Process {
    command: ["nmcli", "monitor"]
    running: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: data => { if (data) debounce.restart() }
    }
  }
  property Timer _debounce: Timer {
    id: debounce
    interval: 250; repeat: false
    onTriggered: { root.refreshStatus(); root.refreshAps() }
  }

  // After `nmcli device wifi connect …` the result isn't visible until NM
  // finishes the handshake; nmcli monitor will fire too, but a guaranteed
  // re-read 1.2s later handles edge cases (e.g. failed auth with no event).
  property Timer _postConnect: Timer {
    id: postConnectTimer
    interval: 1200; repeat: false
    onTriggered: { root.refreshStatus(); root.refreshAps() }
  }
}
