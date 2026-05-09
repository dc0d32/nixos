// Notification popups stacked on the top-right, with persistent history.
// Popups auto-hide after timeout but stay in trackedNotifications for history.
// Notifications older than 1 week are auto-dismissed on startup and hourly.
import Quickshell
import Quickshell.Services.Notifications
import QtQuick
import QtQml.Models

import ".."
import "."

Scope {
  id: nc

  readonly property NotificationServer server: notifServer

  // Ordered list of notification ids as they arrive (oldest first)
  property var popupQueue: []

  readonly property int oneWeekMs: 7 * 24 * 60 * 60 * 1000

  function pruneOld() {
    var now = Date.now()
    var count = notifServer.trackedNotifications.values.length
    for (var i = count - 1; i >= 0; i--) {
      var n = notifServer.trackedNotifications.values[i]
      // hints may carry our arrival timestamp; fall back to now (won't prune fresh ones)
      var arrived = n.hints["x-qs-arrived"] !== undefined ? n.hints["x-qs-arrived"] : now
      if (now - arrived > oneWeekMs)
        n.dismiss()
    }
  }

  NotificationServer {
    id: notifServer
    keepOnReload: true
    actionsSupported: true
    bodyMarkupSupported: true
    bodyImagesSupported: true
    imageSupported: true
    persistenceSupported: true
    extraHints: ["x-qs-arrived"]

    onNotification: n => {
      n.tracked = true
      var q = nc.popupQueue.slice()
      q.push(n.id)
      nc.popupQueue = q
    }
  }

  Timer {
    interval: 60 * 60 * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: nc.pruneOld()
  }

  Variants {
    model: Quickshell.screens
    PanelWindow {
      id: notifWindow
      required property var modelData
      screen: modelData
      anchors { top: true; right: true }
      margins { top: Theme.barHeight + Theme.gap * 2; right: Theme.gap }
      color: "transparent"
      implicitWidth: 360
      // When there are no notification popups, hide the entire
      // PanelWindow surface. The previous `Math.max(1, ...)`
      // dance kept a 1px-tall surface mapped at all times to
      // satisfy WlrLayershell's "non-zero size" requirement,
      // which was harmless when surfaces had no backdrop effect
      // \u2014 but the catch-all layer-rule blur in niri.nix now
      // renders that 360x1 strip as a visible blurred line at
      // the top-right of the screen. Setting `visible: false`
      // unmaps the surface entirely, so niri renders nothing.
      visible: col.implicitHeight > 0
      implicitHeight: Math.max(1, col.implicitHeight + (col.implicitHeight > 0 ? Theme.gap : 0))

      mask: Region {
        item: col.implicitHeight > 0 ? col : null
      }

      Column {
        id: col
        x: 0; y: 0
        width: parent.width
        spacing: Theme.gap

        Instantiator {
          model: notifServer.trackedNotifications
          delegate: NotificationPopup {
            required property Notification modelData
            notification: modelData
            width: col.width
            withinLimit: nc.popupQueue.slice(-5).indexOf(modelData.id) !== -1
          }
          onObjectAdded:   (index, obj) => obj.parent = col
          onObjectRemoved: (index, obj) => obj.parent = null
        }
      }
    }
  }
}
