// Power menu flyout: Lock / Logout / Suspend / Hibernate / Reboot / Shutdown.
//
// Action wiring:
//   Lock      — quickshell ipc call lock lock (same path as idled / niri keybind)
//   Logout    — niri msg action quit (terminates the niri session cleanly)
//   Suspend   — systemctl suspend
//   Hibernate — systemctl hibernate (this host has swap >= RAM; see battery.nix)
//   Reboot    — systemctl reboot
//   Shutdown  — systemctl poweroff
//
// All non-Lock actions use loginctl/systemctl, which run unprivileged via
// polkit's "org.freedesktop.login1.*" actions (granted to active sessions in
// the wheel group). The hyprpolkitagent (flake-modules/polkit-agent.nix)
// handles any auth prompts that surface.
//
// Each click closes the flyout immediately (FlyoutManager.close()) so we don't
// leave a stale UI floating during the system action.
import Quickshell
import QtQuick
import QtQuick.Layouts

import "../.."

Item {
  id: root
  property real chipCenterX: 0
  property real chipWidth:   0

  readonly property int cardWidth: 220
  readonly property int istmusW:   Math.max(chipWidth, 24)

  visible: FlyoutManager.active === "power"

  x: Math.min(Math.max(Math.round(chipCenterX - cardWidth / 2), 0),
              (parent ? parent.width - cardWidth : 0))
  y: Theme.barHeight
  width:  cardWidth
  height: Theme.gap + col.implicitHeight + 20

  function run(cmd) {
    Quickshell.execDetached(cmd)
    FlyoutManager.close()
  }

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
      spacing: 6

      Text {
        font.family: Theme.font; font.pixelSize: 11; font.bold: true
        color: Theme.subtext; text: "SESSION"
        leftPadding: 2
      }

      ProfileButton {
        width: parent.width
        icon: "lock"; label: "Lock"; accent: Theme.blue
        onClicked: root.run([
          "bash", "-c",
          "quickshell ipc --pid $(pgrep -o quickshell) call lock lock"
        ])
      }

      ProfileButton {
        width: parent.width
        icon: "logout"; label: "Logout"; accent: Theme.mauve
        // niri's own quit action — clean session teardown.
        onClicked: root.run(["niri", "msg", "action", "quit", "--skip-confirmation"])
      }

      Rectangle { width: parent.width; height: 1; color: Theme.surface1; opacity: 0.5 }

      Text {
        font.family: Theme.font; font.pixelSize: 11; font.bold: true
        color: Theme.subtext; text: "SYSTEM"
        leftPadding: 2; topPadding: 2
      }

      ProfileButton {
        width: parent.width
        icon: "bedtime"; label: "Suspend"; accent: Theme.teal
        onClicked: root.run(["systemctl", "suspend"])
      }

      ProfileButton {
        width: parent.width
        icon: "downloading"; label: "Hibernate"; accent: Theme.sky
        onClicked: root.run(["systemctl", "hibernate"])
      }

      ProfileButton {
        width: parent.width
        icon: "restart_alt"; label: "Reboot"; accent: Theme.peach
        onClicked: root.run(["systemctl", "reboot"])
      }

      ProfileButton {
        width: parent.width
        icon: "power_settings_new"; label: "Shutdown"; accent: Theme.red
        onClicked: root.run(["systemctl", "poweroff"])
      }
    }
  }
}
