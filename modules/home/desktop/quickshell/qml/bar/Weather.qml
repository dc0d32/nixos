import Quickshell
import QtQuick
import QtQuick.Layouts

import ".."

RowLayout {
  spacing: 2

  Text {
    font.family: Theme.iconFont
    font.pixelSize: 16
    color: Theme.sky
    text: "cloud"
  }

  Text {
    font.family: Theme.font
    font.pixelSize: 12
    color: Theme.subtext
    text: "—"
  }
}