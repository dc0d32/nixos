// App launcher overlay. Opened via `quickshell ipc call launcher open`.
//
// Reads desktop entries from Quickshell.DesktopEntries (which scans
// XDG_DATA_DIRS at startup). User types to filter; Enter / click runs the
// selected entry's exec via DesktopEntry.execute() (proper field-code handling,
// systemd scope wrapping for orphan-survival).
//
// Replaces the `Super+Space → fuzzel` keybind in flake-modules/niri.nix.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts

import ".."

Scope {
  id: root

  property bool shown: false

  function open()  { shown = true }
  function close() { shown = false }
  function toggle(){ shown = !shown }

  Variants {
    model: Quickshell.screens.filter(s => s === Quickshell.primaryScreen || Quickshell.screens.length === 1)
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.shown
      color: "transparent"
      WlrLayershell.layer: WlrLayershell.Overlay
      // Cover the screen so any click outside the card dismisses.
      anchors { top: true; bottom: true; left: true; right: true }
      exclusiveZone: -1
      // Take exclusive keyboard focus while open so typing goes here, not the
      // window underneath.
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

      // dim backdrop + click-to-dismiss
      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
        Rectangle { anchors.fill: parent; color: Theme.crust; opacity: 0.5 }
      }

      // ESC handling lives on the `query` TextInput below, which receives
      // focus immediately on open via `query.forceActiveFocus()`. Layer-shell
      // panels don't expose a top-level `focus` property — keyboard routing
      // is governed entirely by `WlrLayershell.keyboardFocus` (set above).

      Rectangle {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        y: 120
        width: 560
        height: Math.min(parent.height - 240, 60 + listView.contentHeight + 8)
        radius: Theme.radius
        color: Theme.base
        opacity: Theme.opacity
        border.color: Theme.surface1; border.width: 1

        // Reset query when reopened.
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
          anchors.fill: parent
          anchors.margins: 12
          spacing: 8

          // search field
          Rectangle {
            Layout.fillWidth: true
            height: 40
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
                color: Theme.subtext; text: "search"
              }

              TextInput {
                id: query
                Layout.fillWidth: true
                font.family: Theme.font; font.pixelSize: 15; color: Theme.text
                focus: root.shown
                Keys.onDownPressed:   listView.incrementCurrentIndex()
                Keys.onUpPressed:     listView.decrementCurrentIndex()
                Keys.onReturnPressed: {
                  const entry = listView.model[listView.currentIndex]
                  if (entry) {
                    entry.execute()
                    root.close()
                  }
                }
                Keys.onEscapePressed: root.close()
              }
            }
          }

          // results
          ListView {
            id: listView
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 2
            currentIndex: 0
            highlightFollowsCurrentItem: true
            keyNavigationEnabled: false  // input handled by query

            model: {
              const q = query.text.toLowerCase().trim()
              const all = DesktopEntries.applications.values
                .filter(e => !e.noDisplay)
              if (q === "") {
                return all.slice().sort((a, b) => a.name.localeCompare(b.name))
              }
              const scored = []
              for (const e of all) {
                const name = (e.name || "").toLowerCase()
                const generic = (e.genericName || "").toLowerCase()
                const comment = (e.comment || "").toLowerCase()
                let score = -1
                if (name.startsWith(q))      score = 0
                else if (name.includes(q))   score = 1
                else if (generic.includes(q)) score = 2
                else if (comment.includes(q)) score = 3
                else continue
                scored.push({ e, score, name })
              }
              scored.sort((a, b) => a.score - b.score || a.name.localeCompare(b.name))
              return scored.map(x => x.e)
            }

            delegate: Rectangle {
              required property var modelData
              required property int index
              width: ListView.view.width
              height: 44
              radius: Theme.radius - 2
              color: ListView.isCurrentItem ? Theme.surface1 : (hov.containsMouse ? Theme.surface0 : "transparent")

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10; anchors.rightMargin: 10
                spacing: 10

                IconImage {
                  Layout.preferredWidth: 28; Layout.preferredHeight: 28
                  source: modelData.icon ? Quickshell.iconPath(modelData.icon, "application-x-executable") : ""
                  asynchronous: true
                  smooth: true
                }

                Column {
                  Layout.fillWidth: true
                  spacing: 1
                  Text {
                    width: parent.width
                    font.family: Theme.font; font.pixelSize: 13; color: Theme.text
                    text: modelData.name
                    elide: Text.ElideRight
                  }
                  Text {
                    visible: modelData.genericName && modelData.genericName !== modelData.name
                    width: parent.width
                    font.family: Theme.font; font.pixelSize: 10; color: Theme.muted
                    text: modelData.genericName
                    elide: Text.ElideRight
                  }
                }
              }

              MouseArea {
                id: hov
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: listView.currentIndex = parent.index
                onClicked: {
                  listView.currentIndex = parent.index
                  const entry = listView.model[listView.currentIndex]
                  if (entry) {
                    entry.execute()
                    root.close()
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  IpcHandler {
    target: "launcher"
    function open()   { root.open() }
    function close()  { root.close() }
    function toggle() { root.toggle() }
  }
}
