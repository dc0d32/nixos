// Tracks which bar flyout is currently open. Only one open at a time.
// Usage: FlyoutManager.toggle("volume")  /  FlyoutManager.close()
pragma Singleton
import QtQuick

QtObject {
  id: root

  property string active: ""   // "" = none open

  function toggle(name) {
    root.active = (root.active === name) ? "" : name
  }

  function close() {
    root.active = ""
  }
}
