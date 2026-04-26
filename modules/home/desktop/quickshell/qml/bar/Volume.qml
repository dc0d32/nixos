// Volume via PipeWire (wpctl). Scroll to adjust.
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

import ".."

RowLayout {
  id: root
  spacing: 4

  property int  volume: 0   // 0..100
  property bool muted:  false

  Process {
    id: poller
    command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        // e.g. "Volume: 0.42 [MUTED]" or "Volume: 0.65"
        const m = text.match(/Volume:\s+([0-9.]+)(\s+\[MUTED\])?/)
        if (m) {
          root.volume = Math.round(parseFloat(m[1]) * 100)
          root.muted = !!m[2]
        }
      }
    }
  }

  Timer { interval: 50; running: true; repeat: true; onTriggered: poller.running = true }

  Text {
    font.family: Theme.iconFont
    font.pixelSize: 16
    color: root.muted ? Theme.muted : Theme.peach
    text: root.muted ? "volume_off"
        : root.volume === 0 ? "volume_mute"
        : root.volume < 40  ? "volume_down"
                            : "volume_up"
  }
  Text {
    font.family: Theme.font
    font.pixelSize: 12
    color: Theme.subtext
    text: root.muted ? "mute" : root.volume + "%"
    Layout.preferredWidth: 40
  }

  MouseArea {
    Layout.preferredWidth: 10
    Layout.fillHeight: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onClicked: mouse.button === Qt.MiddleButton
      && Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
    onWheel: {
      const delta = wheel.angleDelta.y > 0 ? "5%+" : "5%-"
      Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", delta])
      wheel.accepted = true
    }
  }
}
