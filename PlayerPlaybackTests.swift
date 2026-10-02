//
//  PlayerPlaybackTests.swift
//  iinaTests
//
//  Tests that open a folder of fragmented MP4s in a real player as IINA does, then seek, pause and move between its entries.
//

import AppKit
import Testing
@testable import IINA

/// Each test makes its own player, opens the middle file of its own folder of three copies of `fragmented.mp4` (4 s, a keyframe
/// every second) and closes the player's window at the end. The settings that would make the run write the user's recent files,
/// history or watch-later positions, quit the app or leave pausing to chance are overridden in memory for the test, never on disk.
@Suite("A player playing a folder of fragmented files", .serialized)
@MainActor
struct PlayerPlaybackTests {

  /// Fault threshold for waiting on the player, not an estimate of how long it takes.
  private static let faultTimeout: Duration = .seconds(30)

  /// Settings the tests run under, set in the argument domain so that nothing is written to the user's settings.
  private static let settings: [String: Any] = [
    Preference.Key.resumeLastPosition.rawValue: false,
    Preference.Key.recordRecentFiles.rawValue: false,
    Preference.Key.recordPlaybackHistory.rawValue: false,
    Preference.Key.trackAllFilesInRecentOpenMenu.rawValue: false,
    Preference.Key.quitWhenNoOpenedWindow.rawValue: false,
    Preference.Key.keepOpenOnFileEnd.rawValue: true,
    Preference.Key.fullScreenWhenOpen.rawValue: false,
    Preference.Key.enableThumbnailPreview.rawValue: false,
    Preference.Key.autoRepeat.rawValue: false,
    Preference.Key.playlistAutoAdd.rawValue: true,
    Preference.Key.pauseWhenOpen.rawValue: true,
  ]

  private static var playerCount = 0

  /// A folder holding `a.mp4`, `b.mp4` and `c.mp4`, each a copy of `fragmented.mp4`.
  private static func makeFolder() throws -> URL {
    let source = try #require(Bundle(for: PlayerPlaybackTestsBundle.self).url(forResource: "fragmented", withExtension: "mp4"))
    // Not under the temporary directory, whose path goes through the /var symlink, so that the path of the opened file and the
    // paths of the files found in its folder have the same form.
    let caches = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
    let folder = caches.appendingPathComponent("iinaTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["a", "b", "c"] {
      try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("\(name).mp4"))
    }
    return folder
  }

  /// Open `b.mp4` of a new folder in a new player under the test settings, run `body` once the play state of the file has been
  /// decided and the folder's other files are in the playlist, then close the player's window and restore the settings.
  private static func withPlayer(_ body: (PlayerCore, URL) async throws -> Void) async throws {
    let defaults = UserDefaults.standard
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(arguments.merging(settings) { $1 }, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let player = PlayerCore()
    // Like PlayerCore.createPlayerCore, label the player before it logs anything, since its log subsystem is named after it.
    player.label = "iinaTests-playback-\(playerCount)"
    playerCount += 1
    player.startMPV()
    current = player
    defer { current = nil }
    player.openURL(folder.appendingPathComponent("b.mp4"))
    try await waitUntil { player.info.state == .paused && player.mpv.getInt(MPVProperty.playlistCount) == 3 }
    do {
      try await body(player, folder)
    } catch {
      player.mainWindow.close()
      throw error
    }
    player.mainWindow.close()
    try await waitUntil { player.info.state == .idle }
  }

  /// Wait until `condition` holds, failing the test once the fault threshold passes.
  private static func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + faultTimeout
    while !condition() {
      try #require(ContinuousClock.now < deadline, "Waited \(faultTimeout) for the player: \(current?.testState ?? "")")
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// The player of the running test, described when a wait fails.
  private static var current: PlayerCore?

  /// Wait until playback is at `time`, give or take a frame.
  private static func waitForPosition(_ time: Double, of player: PlayerCore) async throws {
    try await waitUntil { abs(player.mpv.getDouble(MPVProperty.timePos) - time) < 0.11 }
  }

  /// Wait until `mpv` is playing the entry at `index` and its play state has been decided.
  private static func waitForEntry(_ index: Int, of player: PlayerCore) async throws {
    try await waitUntil {
      player.mpv.getInt(MPVProperty.playlistPos) == index && player.info.state == .paused && !player.info.pausedForLoading
    }
  }

  @Test("A file opened from a folder is joined by the folder's other files in folder order and shown paused")
  func opened() async throws {
    try await Self.withPlayer { player, folder in
      player.getPlaylist()
      let paths = ["a", "b", "c"].map { folder.appendingPathComponent("\($0).mp4").path }
      #expect(player.info.playlist.map(\.filename) == paths)
      #expect(player.info.playlist.map(\.isCurrent) == [false, true, false])
      #expect(player.mpv.getFlag(MPVOption.PlaybackControl.pause))
      #expect(player.isVideoLoaded)
      // The full length is worked out off the main thread once the play state has been decided.
      try await Self.waitUntil { player.info.videoDuration?.second ?? 0 >= 4 - 1e-6 }
      #expect(player.mainWindow.videoView.value(forKey: "wantsBestResolutionOpenGLSurface") as? Bool == true)
    }
  }

  @Test("Seeks by percentage and by seconds move playback within the file")
  func seeks() async throws {
    try await Self.withPlayer { player, _ in
      player.seek(percent: 50, forceExact: true)
      try await Self.waitForPosition(2, of: player)
      player.seek(relativeSecond: -1, option: .exact)
      try await Self.waitForPosition(1, of: player)
      player.seek(relativeSecond: 1, option: .relative)
      try await Self.waitForPosition(2, of: player)
      player.seek(relativeSecond: 1, option: .auto)
      try await Self.waitForPosition(3, of: player)
      player.seek(relativeSecond: -2, option: .exact, byScrolling: true)
      try await Self.waitForPosition(1, of: player)
    }
  }

  @Test("Steps and plays move between the entries, each paused when opened")
  func steps() async throws {
    try await Self.withPlayer { player, _ in
      player.navigateInPlaylist(nextMedia: true)
      try await Self.waitForEntry(2, of: player)
      player.navigateInPlaylist(nextMedia: false)
      try await Self.waitForEntry(1, of: player)
      player.playFileInPlaylist(0)
      try await Self.waitForEntry(0, of: player)
      // A step back from the first entry while it plays goes to its start instead.
      player.seek(percent: 50, forceExact: true)
      try await Self.waitForPosition(2, of: player)
      player.getPlaylist()
      #expect(player.isFirstEntryPlaying)
      player.navigateInPlaylist(nextMedia: false)
      try await Self.waitForPosition(0, of: player)
      #expect(player.mpv.getInt(MPVProperty.playlistPos) == 0)
    }
  }

  @Test("The play button resumes paused playback and pauses it again")
  func playButton() async throws {
    try await Self.withPlayer { player, _ in
      player.togglePause()
      // mpv's pause notice reaches the main thread after the resume, and the button acts on the play state it sets.
      try await Self.waitUntil { !player.mpv.getFlag(MPVOption.PlaybackControl.pause) && player.info.state == .playing }
      player.mainWindow.playButtonAction(NSButton())
      try await Self.waitUntil { player.mpv.getFlag(MPVOption.PlaybackControl.pause) }
      #expect(player.info.userPauseCount == 1)
    }
  }

  @Test("Moving the mouse over the play slider shows the time under it")
  func timePreview() async throws {
    try await Self.withPlayer { player, _ in
      let window = try #require(player.mainWindow.window)
      let slider = try #require(player.mainWindow.playSlider)
      let point = slider.convert(NSPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: nil)
      let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: 0, pressure: 0))
      player.mainWindow.mouseMoved(with: event)
      let preview = try #require(player.mainWindow.timePreviewView)
      #expect(!preview.isHidden)
      // The preview is centred on the mouse, see MainWindowController.updateTimePreview.
      let centre = preview.frame.midX
      #expect(abs(centre - point.x) <= 1)
    }
  }
}

private final class PlayerPlaybackTestsBundle {}

private extension PlayerCore {
  /// The state of the player and of its `mpv` core that the tests wait on.
  var testState: String {
    "state \(info.state), pausedForLoading \(info.pausedForLoading), playlist-count \(mpv.getInt(MPVProperty.playlistCount)), "
      + "playlist-pos \(mpv.getInt(MPVProperty.playlistPos)), pause \(mpv.getFlag(MPVOption.PlaybackControl.pause)), "
      + "time-pos \(mpv.getDouble(MPVProperty.timePos)), duration \(info.videoDuration?.second ?? -1)"
  }
}
