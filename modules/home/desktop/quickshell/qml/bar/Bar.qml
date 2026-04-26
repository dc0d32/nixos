// Top bar: [Workspaces] | [ActiveWindow] | [Tray | Media | Weather] | [Net | Vol | Brightness | Clock]
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
    anchors.leftMargin: 8
    anchors.rightMargin: 8
    spacing: 0

    // LEFT: Workspaces | Separator
    Workspaces { }
    Rectangle {
      width: 1
      implicitWidth: 1
      color: Theme.surface1
      Layout.leftMargin: 8
      Layout.rightMargin: 8
    }

    // Spacer
    Item { Layout.fillWidth: true }

    // CENTER: Active window title
    ActiveWindow { Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter }

    // Spacer
    Item { Layout.fillWidth: true }

    // RIGHT: System tray, media, weather
    RowLayout {
      Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
      spacing: 0
      SystemTray { }
      Media { }
      Weather { }
    }

    // Separator
    Rectangle {
      width: 1
      implicitWidth: 1
      color: Theme.surface1
      Layout.leftMargin: 8
      Layout.rightMargin: 8
    }

    // RIGHT EDGE: Network, Volume, Brightness, Clock
    RowLayout {
      Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
      spacing: 0
      Network { }
      Volume { }
      Battery { }
      Brightness { }
      Clock { }
    }
  }
}