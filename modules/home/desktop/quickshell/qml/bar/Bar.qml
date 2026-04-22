// Top bar: [Workspaces] ................ [Clock] ................ [Tray | Net | Vol | Bat]
import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts

import ".."

PanelWindow {
  id: bar

  anchors {
    top: true
    left: true
    right: true
  }

  margins {
    top: Theme.gap
    left: Theme.gap
    right: Theme.gap
  }

  implicitHeight: Theme.barHeight
  color: "transparent"
  WlrLayershell.namespace: "quickshell-bar"
  WlrLayershell.layer: WlrLayershell.Top
  WlrLayershell.exclusiveZone: Theme.barHeight + Theme.gap

  Rectangle {
    anchors.fill: parent
    radius: Theme.radius
    color: Theme.base
    opacity: Theme.opacity
    border.color: Theme.surface1
    border.width: 1
  }

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: 12
    anchors.rightMargin: 12
    spacing: Theme.gap * 2

    Workspaces { Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter }

    Item { Layout.fillWidth: true }

    Clock { Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter }

    Item { Layout.fillWidth: true }

    RowLayout {
      Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
      spacing: Theme.gap
      SystemTray { }
      Network    { }
      Volume     { }
      Battery    { }
    }
  }
}
