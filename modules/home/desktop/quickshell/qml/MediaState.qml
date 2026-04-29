// Singleton: MPRIS player selector. Picks the currently-playing player
// (or any available player as fallback) and re-evaluates whenever the
// player list changes. Replaces the triplicated player-selection
// expression in Media.qml / MediaFlyout.qml / MediaOsd.qml.
//
// Surface:
//   player : MprisPlayer|null
//
// Reactivity: bound to Mpris.players.values via a property binding plus a
// Connections trigger so newly-appearing or vanishing players cause a
// reselection without polling.
pragma Singleton

import Quickshell
import Quickshell.Services.Mpris
import QtQuick

QtObject {
  id: root

  property MprisPlayer player: null

  function _select() {
    const players = Mpris.players.values
    if (!players || players.length === 0) { root.player = null; return }
    const playing = players.find(p => p && p.playbackState === MprisPlaybackState.Playing)
    root.player = playing || players[0] || null
  }

  Component.onCompleted: _select()

  // Re-select when the player list changes.
  property Connections _onPlayers: Connections {
    target: Mpris.players
    function onValuesChanged() { root._select() }
  }

  // Re-select when the current player's playback state flips, so a paused
  // player yields to a newly-playing one without waiting for the values
  // array itself to change.
  property Connections _onState: Connections {
    target: root.player
    ignoreUnknownSignals: true
    function onPlaybackStateChanged() { root._select() }
  }
}
