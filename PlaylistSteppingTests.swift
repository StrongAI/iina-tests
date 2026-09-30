//
//  PlaylistSteppingTests.swift
//  iinaTests
//
//  Tests for moving playback to another playlist entry at the user's command, and for pausing playback while it moves.
//

import Testing
@testable import IINA

/// A player that records what stepping between playlist entries asks of it.
final class SteppingPlayer: PlaylistSteppingPlayer {
  var playerState: PlayerState = .playing
  var isMpvPaused = false
  var pausedForLoading = false
  var isInteractiveModeActive = false
  var isFirstEntryPlaying = false
  /// The value `mpv` returns for a command to move to another entry.
  var moveReturnValue: Int32 = 0
  /// What the player was asked to do, in order.
  private(set) var calls: [String] = []
  /// The messages logged, in order.
  private(set) var messages: [String] = []

  func seekToStart() { calls.append("seekToStart") }

  func movePlaylistPosition(forward: Bool, reply: @escaping (Int32) -> Void) {
    calls.append(forward ? "moveForward" : "moveBackward")
    reply(moveReturnValue)
  }

  func playPlaylistEntry(at index: Int) { calls.append("playEntry \(index)") }

  func refreshPlaylist() { calls.append("refreshPlaylist") }

  func pauseMpv() {
    calls.append("pauseMpv")
    isMpvPaused = true
  }

  func resume() { calls.append("resume") }

  func cancelThumbnailGeneration() { calls.append("cancelThumbnailGeneration") }

  func displayActive() { calls.append("displayActive") }

  func log(_ message: @autoclosure () -> String, level: Logger.Level) { messages.append(message()) }
}

@Suite("Stepping between playlist entries")
struct PlaylistStepTests {

  @Test("A step is ignored while the window is in interactive mode", arguments: [true, false])
  func interactiveModeIgnoresStep(forward: Bool) {
    let player = SteppingPlayer()
    player.isInteractiveModeActive = true
    player.isFirstEntryPlaying = true
    PlaylistStepping.step(player, forward: forward)
    #expect(player.calls.isEmpty)
    #expect(player.messages.isEmpty)
    #expect(!player.pausedForLoading)
  }

  @Test("A step back while the first entry is playing restarts that entry")
  func stepBackAtFirstEntryRestarts() {
    let player = SteppingPlayer()
    player.isFirstEntryPlaying = true
    PlaylistStepping.step(player, forward: false)
    #expect(player.calls == ["seekToStart"])
    #expect(!player.pausedForLoading)
  }

  @Test("A step forward while the first entry is playing moves to the next entry")
  func stepForwardAtFirstEntryMoves() {
    let player = SteppingPlayer()
    player.isFirstEntryPlaying = true
    PlaylistStepping.step(player, forward: true)
    #expect(player.calls == ["moveForward", "cancelThumbnailGeneration", "displayActive", "pauseMpv"])
    #expect(player.pausedForLoading)
  }

  @Test("A step mpv refuses leaves playback unchanged", arguments: [true, false])
  func refusedStepLeavesPlayback(forward: Bool) {
    let player = SteppingPlayer()
    player.moveReturnValue = -12
    PlaylistStepping.step(player, forward: forward)
    #expect(player.calls == [forward ? "moveForward" : "moveBackward"])
    #expect(!player.isMpvPaused)
    #expect(!player.pausedForLoading)
    #expect(player.messages == ["Not playing \(forward ? "next" : "previous") entry in playlist, there is no entry to move to"])
  }

  @Test("A step mpv accepts while playing pauses playback for the loading of the entry", arguments: [true, false])
  func acceptedStepWhilePlayingPauses(forward: Bool) {
    let player = SteppingPlayer()
    PlaylistStepping.step(player, forward: forward)
    #expect(player.calls == [forward ? "moveForward" : "moveBackward", "cancelThumbnailGeneration", "displayActive",
                             "pauseMpv"])
    #expect(player.pausedForLoading)
    #expect(player.messages == ["Pausing playback before playing \(forward ? "next" : "previous") entry in playlist"])
  }

  @Test("A step mpv accepts while paused keeps playback paused for the loading of the entry")
  func acceptedStepWhilePausedKeepsPause() {
    let player = SteppingPlayer()
    player.isMpvPaused = true
    player.playerState = .paused
    PlaylistStepping.step(player, forward: true)
    #expect(player.calls == ["moveForward", "cancelThumbnailGeneration", "displayActive"])
    #expect(player.pausedForLoading)
    #expect(player.messages.isEmpty)
  }

  @Test("Playing an entry by index leaves the entry playing before asking mpv to play it")
  func playEntryAtIndex() {
    let player = SteppingPlayer()
    PlaylistStepping.play(player, at: 3)
    #expect(player.calls == ["cancelThumbnailGeneration", "displayActive", "pauseMpv", "playEntry 3", "refreshPlaylist"])
    #expect(player.pausedForLoading)
    #expect(player.messages == ["Pausing playback before playing entry at index 3 in the playlist"])
  }

  @Test("Playing an entry by index while paused does not pause again")
  func playEntryAtIndexWhilePaused() {
    let player = SteppingPlayer()
    player.isMpvPaused = true
    PlaylistStepping.play(player, at: 0)
    #expect(player.calls == ["cancelThumbnailGeneration", "displayActive", "playEntry 0", "refreshPlaylist"])
    #expect(player.pausedForLoading)
  }
}

@Suite("Pausing during a step")
struct PlaylistPauseTests {

  @Test("Toggling while paused by the user resumes playback")
  func toggleWhilePausedResumes() {
    let player = SteppingPlayer()
    player.playerState = .paused
    player.isMpvPaused = true
    PlaylistStepping.togglePause(player)
    #expect(player.calls == ["resume"])
  }

  @Test("Toggling while paused for the loading of an entry pauses and holds the pause")
  func toggleWhilePausedForLoadingPauses() {
    let player = SteppingPlayer()
    player.playerState = .paused
    player.isMpvPaused = true
    player.pausedForLoading = true
    PlaylistStepping.togglePause(player)
    #expect(player.calls == ["pauseMpv"])
    #expect(!player.pausedForLoading)
    #expect(player.messages == ["Pausing playback"])
  }

  @Test("Toggling in a state other than paused pauses",
        arguments: [PlayerState.loading, .starting, .loaded, .playing])
  func toggleWhileNotPausedPauses(state: PlayerState) {
    let player = SteppingPlayer()
    player.playerState = state
    player.pausedForLoading = true
    PlaylistStepping.togglePause(player)
    #expect(player.calls == ["pauseMpv"])
    #expect(!player.pausedForLoading)
  }

  @Test("A pause while the player is not active does nothing",
        arguments: [PlayerState.stopping, .idle, .shuttingDown, .shutDown])
  func pauseWhileInactiveDoesNothing(state: PlayerState) {
    let player = SteppingPlayer()
    player.playerState = state
    player.pausedForLoading = true
    PlaylistStepping.pause(player)
    #expect(player.calls.isEmpty)
    #expect(player.pausedForLoading)
  }

  @Test("A pause given while an entry loads ends the pause for loading", arguments: [PlayerState.loading, .starting, .loaded])
  func pauseWhileLoadingEndsPauseForLoading(state: PlayerState) {
    let player = SteppingPlayer()
    player.playerState = state
    player.isMpvPaused = true
    player.pausedForLoading = true
    PlaylistStepping.pause(player)
    #expect(player.calls == ["pauseMpv"])
    #expect(!player.pausedForLoading)
  }
}
