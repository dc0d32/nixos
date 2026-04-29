// Singleton: owns one long-running `niri msg --json event-stream` Process and
// exposes the live workspace list and focused-window state to the rest of the
// shell. Replaces the previous per-widget 500ms polling subprocesses.
//
// niri's event protocol (line-delimited JSON):
//   {"WorkspacesChanged": {"workspaces": [...]}}        — full workspace list
//   {"WorkspaceActivated": {"id":N, "focused":bool}}     — id of new active ws
//   {"WindowsChanged":  {"windows": [...]}}              — full window list
//   {"WindowOpenedOrChanged": {"window": {...}}}         — single window upd
//   {"WindowClosed": {"id": N}}
//   {"WindowFocusChanged": {"id": N|null}}               — id of newly-focused
//
// We hold the full windows-by-id map and the workspaces array; selectors
// derive the "currently focused window" object on demand.
pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick

QtObject {
  id: root

  property var workspaces: []                // live list, sorted by idx
  property int focusedWindowId: -1
  property var windowsById: ({})             // map id → window object

  // Convenience selector. Recomputed whenever windowsById or focusedWindowId
  // changes; QML's binding engine handles the dependency tracking.
  readonly property var focusedWindow:
    focusedWindowId >= 0 ? (windowsById[focusedWindowId] || null) : null

  function _onEvent(line) {
    if (!line) return
    var ev
    try { ev = JSON.parse(line) } catch (_) { return }
    if (!ev || typeof ev !== "object") return

    if (ev.WorkspacesChanged) {
      const ws = (ev.WorkspacesChanged.workspaces || []).slice()
      ws.sort((a, b) => a.idx - b.idx)
      workspaces = ws
    } else if (ev.WorkspaceActivated) {
      // Update the active flag in-place without losing the rest of the state.
      const id = ev.WorkspaceActivated.id
      const next = workspaces.map(w => Object.assign({}, w, {
        is_active:  w.id === id,
        is_focused: w.id === id ? !!ev.WorkspaceActivated.focused : w.is_focused,
      }))
      workspaces = next
    } else if (ev.WindowsChanged) {
      const map = {}
      for (const w of (ev.WindowsChanged.windows || [])) map[w.id] = w
      windowsById = map
      // Initial focus from the snapshot, in case WindowFocusChanged hasn't
      // arrived yet.
      const f = (ev.WindowsChanged.windows || []).find(w => w.is_focused)
      if (f) focusedWindowId = f.id
    } else if (ev.WindowOpenedOrChanged) {
      const w = ev.WindowOpenedOrChanged.window
      if (w) {
        const m = Object.assign({}, windowsById)
        m[w.id] = w
        windowsById = m
        if (w.is_focused) focusedWindowId = w.id
      }
    } else if (ev.WindowClosed) {
      const id = ev.WindowClosed.id
      if (id !== undefined && windowsById[id]) {
        const m = Object.assign({}, windowsById)
        delete m[id]
        windowsById = m
        if (focusedWindowId === id) focusedWindowId = -1
      }
    } else if (ev.WindowFocusChanged) {
      focusedWindowId = ev.WindowFocusChanged.id == null ? -1 : ev.WindowFocusChanged.id
    }
    // Other events (KeyboardLayoutsChanged, OverviewOpenedOrClosed,
    // ConfigLoaded) are ignored.
  }

  // The actual subscription. Quickshell restarts the Process if `running`
  // remains true and the child exits, so a niri restart is recoverable.
  property Process _proc: Process {
    command: ["niri", "msg", "--json", "event-stream"]
    running: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: data => root._onEvent(data)
    }
  }
}
