// Singleton: Pipewire default audio sink wrapper. Reactive (no polling).
// Replaces the previous 200ms `wpctl get-volume` Timer in VolumeFlyout.qml
// and the awk/grep/sed `wpctl status` sink-name pipeline.
//
// PwObjectTracker is required to keep the node's `audio` sub-object alive
// and emitting change signals.
//
// Surface:
//   sink     : PwNode|null — current default sink (or null on systems w/o pipewire)
//   audio    : PwNodeAudio|null
//   volume   : int   — 0..150 (rounded percent)
//   muted    : bool
//   sinkName : string  — human-readable; falls back through nickname/description/name
pragma Singleton

import Quickshell
import Quickshell.Services.Pipewire
import QtQuick

QtObject {
  id: root

  readonly property var sink:  Pipewire.defaultAudioSink
  readonly property var audio: sink ? sink.audio : null

  readonly property int  volume: audio ? Math.round((audio.volume || 0) * 100) : 0
  readonly property bool muted:  audio ? !!audio.muted : false

  readonly property string sinkName:
    !sink                    ? "Default Sink"
  : (sink.nickname    || "") ? sink.nickname
  : (sink.description || "") ? sink.description
  : (sink.name        || "") ? sink.name
  :                            "Default Sink"

  // Keep the sink's audio sub-object alive and emitting volume/muted change
  // signals. Without this binding, `audio.volume` etc. report stale values.
  property PwObjectTracker _tracker: PwObjectTracker {
    objects: Pipewire.defaultAudioSink ? [Pipewire.defaultAudioSink] : []
  }
}
