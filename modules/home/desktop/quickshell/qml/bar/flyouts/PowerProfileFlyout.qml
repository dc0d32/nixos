// Power profile flyout: three buttons for Power Saver / Balanced / Performance.
import Quickshell
import Quickshell.Services.UPower
import QtQuick
import QtQuick.Layouts

import "../.."

Item {
  id: root
  property real chipCenterX: 0
  property real chipWidth:   0

  readonly property int cardWidth: 220
  readonly property int istmusW:   Math.max(chipWidth, 24)

  visible: FlyoutManager.active === "powerprofile"

  x: Math.min(Math.max(Math.round(chipCenterX - cardWidth / 2), 0),
              (parent ? parent.width - cardWidth : 0))
  y: Theme.barHeight
  width:  cardWidth
  height: Theme.gap + col.implicitHeight + 20

  // isthmus
  Isthmus {
    cardWidth: root.cardWidth
    neckWidth: root.istmusW
    fillColor: Theme.base
  }

  // card
  Rectangle {
    x: 0; y: Theme.gap; width: root.cardWidth
    implicitHeight: col.implicitHeight + 20
    radius: Theme.radius; color: Theme.base; opacity: Theme.opacity
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
