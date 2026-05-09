// Power profile flyout: three buttons for Power Saver / Balanced / Performance.
import Quickshell
import Quickshell.Services.UPower
import QtQuick
import QtQuick.Layouts

import "../.."

FlyoutWindow {
  id: root
  flyoutName: "powerprofile"
  cardWidth: 220
  cardImplicitHeight: card.implicitHeight

  readonly property int istmusW: Math.max(chipWidth, 24)

  // isthmus
  Isthmus {
    cardWidth: root.cardWidth
    neckWidth: root.istmusW
    fillColor: Theme.base
  }

  // card
  Rectangle {
    id: card
    x: 0; y: Theme.gap; width: root.cardWidth
    implicitHeight: col.implicitHeight + 20
    radius: Theme.radius; color: Theme.base; opacity: Theme.panelOpacity
    border.color: Theme.surface1; border.width: 1

    Column {
      id: col
      anchors { top: parent.top; left: parent.left; right: parent.right }
      anchors.margins: 14; anchors.topMargin: 14
      spacing: 8

      Text {
        font.family: Theme.font; font.pixelSize: 11; font.bold: true
        color: Theme.subtext; text: "POWER PROFILE"
        leftPadding: 2
      }

      // Power Saver
      ProfileButton {
        width: parent.width
        icon:    "battery_saver"
        label:   "Power Saver"
        active:  PowerProfiles.profile === PowerProfile.PowerSaver
        accent:  Theme.blue
        onClicked: PowerProfiles.profile = PowerProfile.PowerSaver
      }

      // Balanced
      ProfileButton {
        width: parent.width
        icon:    "eco"
        label:   "Balanced"
        active:  PowerProfiles.profile === PowerProfile.Balanced
        accent:  Theme.green
        onClicked: PowerProfiles.profile = PowerProfile.Balanced
      }

      // Performance (hidden when unavailable)
      ProfileButton {
        width:   parent.width
        visible: PowerProfiles.hasPerformanceProfile
        icon:    "bolt"
        label:   "Performance"
        active:  PowerProfiles.profile === PowerProfile.Performance
        accent:  Theme.red
        onClicked: PowerProfiles.profile = PowerProfile.Performance
      }
    }
  }
}
