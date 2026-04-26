// Fuzzy app launcher. Reads desktop entries via Quickshell.Services.DesktopEntries.
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.DesktopEntries
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

Scope {
  id: root
  property bool open: false
  function toggle() { root.open = !root.open }

  Variants {
    model: Quickshell.screens.filter(s => s === Quickshell.primaryScreen || Quickshell.screens.length === 1)
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.open
      color: "transparent"
      WlrLayershell.layer: WlrLayershell.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      anchors { top: true; bottom: true; left: true; right: true }

      MouseArea {
        anchors.fill: parent
        onClicked: root.open = false
      }

      Rectangle {
        id: dialog
        width: 560
        height: 420
        radius: Theme.radius
        color: Theme.base
        opacity: Theme.opacity
        border.color: Theme.surface2
        border.width: 1
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.2

        Column {
          anchors.fill: parent
          anchors.margins: 12
          spacing: 8

          TextInput {
            id: query
            focus: root.open
            width: parent.width
            font.family: Theme.font
            font.pixelSize: 18
            color: Theme.text
            selectByMouse: true

            Keys.onEscapePressed: root.open = false
            Keys.onReturnPressed: {
              const e = list.currentItem && list.currentItem.entry
              if (e) { e.execute(); root.open = false; query.text = "" }
            }
            Keys.onDownPressed: list.incrementCurrentIndex()
            Keys.onUpPressed:   list.decrementCurrentIndex()
          }

          Rectangle { width: parent.width; height: 1; color: Theme.surface1 }

          ListView {
            id: list
            width: parent.width
            height: parent.height - 60
            clip: true
            currentIndex: 0

            model: DesktopEntries.applications.values.filter(e =>
              !e.noDisplay &&
              (query.text === "" ||
               e.name.toLowerCase().includes(query.text.toLowerCase()) ||
               (e.comment || "").toLowerCase().includes(query.text.toLowerCase()))
            )

            delegate: Rectangle {
              required property var modelData
              property alias entry: _e.modelData
              Item { id: _e; property var modelData: modelData }

              width: list.width
              height: 40
              radius: 6
              color: ListView.isCurrentItem ? Theme.surface1 : "transparent"

              Row {
                anchors.fill: parent; anchors.margins: 8; spacing: 10
                Image { source: modelData.icon; width: 24; height: 24; sourceSize: Qt.size(24,24) }
                Column {
                  Text { font.family: Theme.font; font.pixelSize: 13; color: Theme.text; text: modelData.name }
                  Text { font.family: Theme.font; font.pixelSize: 11; color: Theme.muted; text: modelData.comment || "" }
                }
              }

              MouseArea {
                anchors.fill: parent
                onClicked: { modelData.execute(); root.open = false; query.text = "" }
              }
            }
          }
        }
      }
    }
  }
}
