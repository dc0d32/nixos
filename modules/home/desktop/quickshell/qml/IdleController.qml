import QtQuick
import Quickshell
import Quickshell.Wayland

QtObject {
  property var lockCallback: function() {}
  property var suspendCallback: function() {}
  property var dpmsOffCallback: function() {}
  property var dpmsOnCallback: function() {}

  property int lockTimeout: 300
  property int dpmsTimeout: 420
  property int suspendTimeout: 900

  property bool _dpmsOn: true

  IdleMonitor {
    id: lockIdle
    timeout: lockTimeout
    onIsIdleChanged: {
      if (isIdle && lockIdle.enabled) {
        lockCallback();
      }
    }
  }

  IdleMonitor {
    id: dpmsIdle
    timeout: dpmsTimeout
    onIsIdleChanged: {
      if (isIdle && dpmsIdle.enabled) {
        if (_dpmsOn) {
          _dpmsOn = false;
          dpmsOffCallback();
        }
      } else if (!isIdle && !_dpmsOn) {
        _dpmsOn = true;
        dpmsOnCallback();
      }
    }
  }

  IdleMonitor {
    id: suspendIdle
    timeout: suspendTimeout
    onIsIdleChanged: {
      if (isIdle && suspendIdle.enabled) {
        suspendCallback();
      }
    }
  }
}