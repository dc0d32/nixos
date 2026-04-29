// Active window chip. Reads focusedWindow from the NiriState singleton.
// No polling; updates push from niri's event-stream via NiriState.
import Quickshell
import QtQuick
import QtQuick.Layouts

import ".."

RowLayout {
  id: root
  spacing: 6

  readonly property var win: NiriState.focusedWindow
  readonly property string titleText: win ? (win.title || "") : ""
  readonly property string appName:   win ? (win.app_id || "") : ""

  Text {
    font.family: Theme.font
    font.pixelSize: 11
    color: Theme.subtext
    text: root.appName
    font.bold: true
  }

  Text {
    font.family: Theme.font
    font.pixelSize: 11
    color: Theme.text
    text: root.titleText
    elide: Text.ElideMiddle
    Layout.maximumWidth: 300
  }
}
