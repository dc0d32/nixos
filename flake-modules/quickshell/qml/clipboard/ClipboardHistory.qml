// Clipboard history overlay. Opened via `quickshell ipc call clipboard open`.
//
// Reads `cliphist list` (each line: "<id>\t<preview>"), filters by typed query,
// and on selection: `cliphist decode <id> | wl-copy`.
//
// Replaces the `Mod+Shift+C → cliphist list | fuzzel --dmenu | cliphist decode | wl-copy`
// keybind in flake-modules/niri.nix.
//
// Requires `cliphist` running as a wl-clipboard watcher (the existing setup
// already does this — entries appear in the list as the user copies).
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

import ".."

Scope {
  id: root

  property bool shown: false
  property var entries: []   // [{ id: "123", preview: "..." }]

  function open()   { refresh(); shown = true }
  function close()  { shown = false }
  function toggle() { if (shown) close(); else open() }

  function refresh() { listProc.running = true }

  Process {
    id: listProc
    command: ["cliphist", "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        const lines = text.split("\n")
        const out = []
        for (const line of lines) {
          if (!line) continue
          const tab = line.indexOf("\t")
          if (tab < 0) continue
          out.push({ id: line.substring(0, tab), preview: line.substring(tab + 1) })
        }
        root.entries = out
      }
    }
  }

  function copy(id) {
    // cliphist decode <id> | wl-copy — pipe via bash since execDetached
    // doesn't compose pipes.
    Quickshell.execDetached([
      "bash", "-c",
      "cliphist decode " + id + " | wl-copy"
    ])
    close()
  }

  function deleteEntry(id) {
    Quickshell.execDetached([
      "bash", "-c",
      "cliphist delete-query " + id + " 2>/dev/null || (cliphist list | grep -E '^" + id + "\\b' | cliphist delete)"
    ])
    // refresh after a tick so cliphist has time to flush
    refreshTimer.restart()
  }
  Timer { id: refreshTimer; interval: 150; onTriggered: root.refresh() }

  Variants {
    model: Quickshell.screens.filter(s => s === Quickshell.primaryScreen || Quickshell.screens.length === 1)
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.shown
      color: "transparent"
      WlrLayershell.layer: WlrLayershell.Overlay
      anchors { top: true; bottom: true; left: true; right: true }
      exclusiveZone: -1
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
        Rectangle { anchors.fill: parent; color: Theme.crust; opacity: 0.5 }
      }

      // ESC handling lives on the `query` TextInput below, which receives
      // focus immediately on open via `query.forceActiveFocus()`. PanelWindow
      // doesn't expose a top-level `focus` property; keyboard routing is
      // governed by `WlrLayershell.keyboardFocus` (set above).

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 120
        width: 600
        height: Math.min(parent.height - 240, 60 + listView.contentHeight + 8)
        radius: Theme.radius
        color: Theme.base
        opacity: Theme.opacity
        border.color: Theme.surface1; border.width: 1

        Connections {
          target: root
          function onShownChanged() {
            if (root.shown) {
              query.text = ""
              listView.currentIndex = 0
              query.forceActiveFocus()
            }
          }
        }

        ColumnLayout {
          anchors.fill: parent; anchors.margins: 12; spacing: 8

          Rectangle {
            Layout.fillWidth: true; height: 40
            radius: Theme.radius - 2
            color: Theme.surface0
            border.color: query.activeFocus ? Theme.accent : Theme.surface2
            border.width: 1

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: 12; anchors.rightMargin: 12
              spacing: 8

              Text {
                font.family: Theme.iconFont; font.pixelSize: 18
                color: Theme.subtext; text: "content_paste"
              }

              TextInput {
                id: query
                Layout.fillWidth: true
                font.family: Theme.font; font.pixelSize: 15; color: Theme.text
                focus: root.shown
                Keys.onDownPressed:   listView.incrementCurrentIndex()
                Keys.onUpPressed:     listView.decrementCurrentIndex()
                Keys.onReturnPressed: {
                  const e = listView.model[listView.currentIndex]
                  if (e) root.copy(e.id)
                }
                Keys.onEscapePressed: root.close()
                Keys.onDeletePressed: {
                  const e = listView.model[listView.currentIndex]
                  if (e) root.deleteEntry(e.id)
                }
              }

              Text {
                visible: root.entries.length === 0
                font.family: Theme.font; font.pixelSize: 11; color: Theme.muted
                text: "Empty"
              }
            }
          }

          ListView {
            id: listView
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true; spacing: 2
            currentIndex: 0
            keyNavigationEnabled: false

            model: {
              const q = query.text.toLowerCase().trim()
              if (q === "") return root.entries
              return root.entries.filter(e => e.preview.toLowerCase().includes(q))
            }

            delegate: Rectangle {
              required property var modelData
              required property int index
              width: ListView.view.width
              height: 36
              radius: Theme.radius - 2
              color: ListView.isCurrentItem ? Theme.surface1 : (hov.containsMouse ? Theme.surface0 : "transparent")

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12; anchors.rightMargin: 8
                spacing: 8

                Text {
                  font.family: Theme.monoFont; font.pixelSize: 10
                  color: Theme.muted
                  text: modelData.id
                  Layout.preferredWidth: 40
                  elide: Text.ElideRight
                }

                Text {
                  Layout.fillWidth: true
                  font.family: Theme.font; font.pixelSize: 12; color: Theme.text
                  text: modelData.preview
                  elide: Text.ElideRight
                  maximumLineCount: 1
                }

                Text {
                  visible: hov.containsMouse
                  font.family: Theme.iconFont; font.pixelSize: 14
                  color: Theme.muted; text: "delete"
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.deleteEntry(modelData.id)
                  }
                }
              }

              MouseArea {
                id: hov
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton
                onEntered: listView.currentIndex = parent.index
                onClicked: root.copy(modelData.id)
              }
            }
          }
        }
      }
    }
  }

  IpcHandler {
    target: "clipboard"
    function open()   { root.open() }
    function close()  { root.close() }
    function toggle() { root.toggle() }
  }
}
