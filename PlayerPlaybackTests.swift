//
//  PlayerPlaybackTests.swift
//  iinaTests
//
//  Tests that open a folder of fragmented MP4s in a real player as IINA does, then seek, pause and move between its entries.
//

import AppKit
import MediaPlayer
import Network
import Testing
import WebKit
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
    Preference.Key.horizontalScrollAction.rawValue: Preference.ScrollAction.seek.rawValue,
    Preference.Key.relativeSeekAmount.rawValue: 3,
    Preference.Key.useExactSeek.rawValue: Preference.SeekOption.exact.rawValue,
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

  /// Fault threshold for a hold on the core of a player's `mpv`, not an estimate of how long the hold lasts.
  private static let holdLimit: DispatchTimeInterval = .seconds(30)

  /// Time in which `mpv` would answer a request many times over, were its core not held. A held core answers nothing, so an answer
  /// in this time shows the hold failed.
  private static let heldAnswerWindow: Duration = .milliseconds(300)

  /// Make `request` while the core of the player's `mpv` is held, then let the core go.
  /// - Returns: Whether `request` returned while the core was held, before `mpv` handled it.
  private static func returnsWhileHeld(_ player: PlayerCore, _ request: () -> Void) async throws -> Bool {
    let hold = try MPVCoreHold(player.mpv, limit: holdLimit)
    request()
    let returnedWhileHeld = !hold.hasLetGo
    hold.release()
    // A hold shows something only once the core has reached it, so wait for the core to reach it and go on.
    try await waitUntil { hold.hasLetGo }
    return returnedWhileHeld
  }

  /// Drop `urls` on the player while the core of its `mpv` is held, wait until the player has asked `mpv` for what was dropped, then
  /// let the core go.
  /// - Returns: Whether the player asked while the core was held, which a request that waits for `mpv` cannot do.
  private static func dropRequestsWhileHeld(_ player: PlayerCore, _ urls: [URL]) async throws -> Bool {
    let hold = try MPVCoreHold(player.mpv, limit: holdLimit)
    let waiting = player.mpv.replyCallbacks.count
    #expect(player.openFromPasteboard(FileDrop(urls)))
    // A held core answers nothing, so a request that does not wait stays registered until the core is let go, while one that waits
    // keeps the main thread from checking until the hold reaches its limit and lets go.
    try await waitUntil { player.mpv.replyCallbacks.count > waiting || hold.hasLetGo }
    let requestedWhileHeld = !hold.hasLetGo
    hold.release()
    try await waitUntil { hold.hasLetGo }
    return requestedWhileHeld
  }

  /// Ask `mpv` whether playback is paused and wait for the answer, which comes after its answers to every request made before.
  private static func paused(_ player: PlayerCore) async -> Bool? {
    await withCheckedContinuation { continuation in
      player.mpv.getFlagAsync(MPVOption.PlaybackControl.pause) { continuation.resume(returning: $0) }
    }
  }

  /// Wait until every block the main queue holds has run.
  private static func drainMain() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
  }

  /// Read the player's playlist from `mpv` and wait until it is stored.
  private static func readPlaylist(of player: PlayerCore) async {
    await withCheckedContinuation { continuation in player.getPlaylist { continuation.resume() } }
  }

  /// Run `body` with `settings` added to the test settings in the argument domain, then restore them.
  private static func withSettings(_ settings: [Preference.Key: Any], _ body: () async throws -> Void) async throws {
    let defaults = UserDefaults.standard
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    let added = Dictionary(uniqueKeysWithValues: settings.map { ($0.key.rawValue, $0.value) })
    defaults.setVolatileDomain(arguments.merging(added) { $1 }, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
    try await body()
  }

  /// Open `urls` in the players the settings choose and wait until they have been opened.
  /// - Returns: What `PlayerCore.openURLs` reported once they were opened.
  private static func open(_ urls: [URL]) async -> Int? {
    await withCheckedContinuation { continuation in PlayerCore.openURLs(urls) { continuation.resume(returning: $0) } }
  }

  /// Wait until a player of `PlayerCore` shows each file at `paths`, paused once opened.
  /// - Returns: The player showing each file, in the order of `paths`.
  private static func players(showing paths: [String]) async throws -> [PlayerCore] {
    var players: [PlayerCore] = []
    try await waitUntil {
      players = paths.compactMap { path in PlayerCore.playerCores.first { $0.info.currentURL?.path == path } }
      return players.count == paths.count && players.allSatisfy { $0.info.state == .paused && !$0.info.pausedForLoading }
    }
    return players
  }

  /// Close the windows of `players` and wait until each is idle.
  private static func close(_ players: [PlayerCore]) async throws {
    for player in players {
      player.mainWindow.close()
    }
    try await waitUntil { players.allSatisfy { $0.info.state == .idle } }
  }

  @Test("A file opened from a folder is joined by the folder's other files in folder order and shown paused")
  func opened() async throws {
    try await Self.withPlayer { player, folder in
      await Self.readPlaylist(of: player)
      let paths = ["a", "b", "c"].map { folder.appendingPathComponent("\($0).mp4").path }
      #expect(player.info.playlist.map(\.filename) == paths)
      #expect(player.info.playlist.map(\.isCurrent) == [false, true, false])
      #expect(player.mpv.getFlag(MPVOption.PlaybackControl.pause))
      #expect(player.isVideoLoaded)
      // fileLoaded stores the size read when mpv reported the file loaded, on the queue for reading mpv events.
      #expect((player.info.videoWidth ?? 0) > 0)
      #expect(player.info.videoWidth == player.mpv.getInt(MPVProperty.width))
      #expect(player.info.videoHeight == player.mpv.getInt(MPVProperty.height))
      // The full length is worked out off the main thread once the play state has been decided.
      try await Self.waitUntil { player.info.videoDuration?.second ?? 0 >= 4 - 1e-6 }
      #expect(player.mainWindow.videoView.value(forKey: "wantsBestResolutionOpenGLSurface") as? Bool == true)
    }
  }

  @Test("The folder's other files are added by work at user-initiated priority, which a busy Mac does not hold back")
  func folderPriority() async throws {
    // AutoFileMatcher posts the playlist-changed notification on the thread that added the folder's files, right after adding them.
    let record = PlaylistChangeRecord()
    let observer = NotificationCenter.default.addObserver(forName: .iinaPlaylistChanged, object: nil, queue: nil) { notification in
      guard !Thread.isMainThread, let player = notification.object as? PlayerCore else { return }
      record.add(qos_class_self(), for: player)
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    try await Self.withPlayer { player, _ in
      try await Self.waitUntil { !record.classes(for: player).isEmpty }
      #expect(record.classes(for: player).allSatisfy { $0 == QOS_CLASS_USER_INITIATED })
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

  @Test("Seeks by seconds, to a time and to the start of the file return before mpv handles them")
  func seeksDoNotWait() async throws {
    try await Self.withPlayer { player, _ in
      player.seek(percent: 50, forceExact: true)
      try await Self.waitForPosition(2, of: player)
      let seeks: [(name: String, seek: () -> Void, landing: Double)] = [
        ("exact", { player.seek(relativeSecond: 1, option: .exact) }, 3),
        ("relative", { player.seek(relativeSecond: -1, option: .relative) }, 2),
        ("auto", { player.seek(relativeSecond: 1, option: .auto) }, 3),
        ("scroll", { player.seek(relativeSecond: -2, option: .exact, byScrolling: true) }, 1),
        ("to a time", { player.seek(absoluteSecond: 2) }, 2),
        ("to the start", { player.seekToStart() }, 0),
      ]
      for (name, seek, landing) in seeks {
        let returnedWhileHeld = try await Self.returnsWhileHeld(player, seek)
        #expect(returnedWhileHeld, "The \(name) seek waited for mpv")
        try await Self.waitForPosition(landing, of: player)
      }
    }
  }

  @Test("The time is synchronized with mpv in a request that returns before mpv handles it, then stored")
  func timeSyncDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      player.seek(percent: 50, forceExact: true)
      try await Self.waitForPosition(2, of: player)
      var synced = false
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.syncTime { synced = true } }
      #expect(returnedWhileHeld, "Synchronizing the time waited for mpv")
      try await Self.waitUntil { synced }
      #expect(abs((player.info.videoPosition?.second ?? 0) - 2) < 0.11)
    }
  }

  @Test("Resuming at the end of the last file returns before mpv handles it and plays the file again from its start")
  func resumeAtEndDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      player.playFileInPlaylist(2)
      try await Self.waitForEntry(2, of: player)
      player.seek(absoluteSecond: 3.5)
      try await Self.waitForPosition(3.5, of: player)
      // Playback that reaches the end of the last entry stops there, paused, and mpv reports eof-reached. A paused seek to the end
      // shows the last frame without reaching the end.
      player.mpv.setFlagAsync(MPVOption.PlaybackControl.pause, false)
      try await Self.waitUntil { player.mpv.getFlag(MPVProperty.eofReached) }
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.resume() }
      #expect(returnedWhileHeld, "Resuming waited for mpv")
      try await Self.waitUntil {
        !player.mpv.getFlag(MPVOption.PlaybackControl.pause) && player.mpv.getDouble(MPVProperty.timePos) < 2
      }
    }
  }

  @Test("A pause given before mpv answers a resume keeps playback paused")
  func pauseDuringResumeHolds() async throws {
    try await Self.withPlayer { player, _ in
      let hold = try MPVCoreHold(player.mpv, limit: Self.holdLimit)
      player.resume()
      player.pause()
      hold.release()
      // mpv answers in the order it was asked, and the resume's answer reaches the main queue ahead of this read's.
      #expect(await Self.paused(player) == true)
      await Self.drainMain()
      #expect(await Self.paused(player) == true)
      #expect(player.info.userPauseCount == 1)
    }
  }

  @Test("Resuming before the end returns before mpv handles it and plays on from where playback was")
  func resumeDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      player.seek(percent: 50, forceExact: true)
      try await Self.waitForPosition(2, of: player)
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.resume() }
      #expect(returnedWhileHeld, "Resuming waited for mpv")
      try await Self.waitUntil { !player.mpv.getFlag(MPVOption.PlaybackControl.pause) }
      #expect(player.mpv.getDouble(MPVProperty.timePos) >= 2 - 0.1)
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
      await Self.readPlaylist(of: player)
      #expect(player.isFirstEntryPlaying)
      player.navigateInPlaylist(nextMedia: false)
      try await Self.waitForPosition(0, of: player)
      #expect(player.mpv.getInt(MPVProperty.playlistPos) == 0)
    }
  }

  @Test("A mouse wheel scrolled sideways over the window seeks")
  func scrollSeek() async throws {
    try await Self.withPlayer { player, _ in
      player.seek(percent: 50, forceExact: true)
      try await Self.waitForPosition(2, of: player)
      let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: 1,
                                        wheel3: 0))
      // A mouse wheel scroll begins only once its time is far enough past the last scroll's, see ScrollGesture.
      scroll.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
      let event = try #require(NSEvent(cgEvent: scroll))
      player.mainWindow.scrollWheel(with: event)
      // Which way a sideways wheel turns playback follows the system's scroll direction, so only the move is checked.
      try await Self.waitUntil { abs(player.mpv.getDouble(MPVProperty.timePos) - 2) >= 0.5 }
    }
  }

  @Test("The inspector shows the length of the file being played")
  func inspector() async throws {
    try await Self.withPlayer { player, _ in
      PlayerCore.lastActive = player
      let inspector = InspectorWindowController()
      _ = inspector.window
      defer { inspector.close() }
      inspector.updateInfo()
      let length = VideoTime(4).stringRepresentation
      try await Self.waitUntil { inspector.durationField.stringValue == length }
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

  @Test("Opening a folder returns at once and opens its files without waiting for mpv, the first shown and the rest after it")
  func openDoesNotWait() async throws {
    try await Self.withPlayer { player, folder in
      // A folder URL as Finder gives it, which getPlayableFiles reads as a directory.
      let directory = URL(fileURLWithPath: folder.path, isDirectory: true)
      let hold = try MPVCoreHold(player.mpv, limit: Self.holdLimit)
      var opened: (count: Int?, whileHeld: Bool)?
      player.openURLs([directory]) { opened = ($0, !hold.hasLetGo) }
      let returnedWhileHeld = !hold.hasLetGo
      let returnedBeforeOpening = opened == nil
      // The files are found on the queue for opening files, then opened on the main thread, which this wait leaves free while
      // mpv is held.
      try await Self.waitUntil { opened != nil }
      hold.release()
      try await Self.waitUntil { hold.hasLetGo }
      #expect(returnedWhileHeld, "Opening files waited for mpv")
      #expect(returnedBeforeOpening, "Opening files found and opened them before returning")
      #expect(opened?.whileHeld == true, "Opening the files found waited for mpv")
      #expect(opened?.count == 3)
      let paths = ["a", "b", "c"].map { folder.appendingPathComponent("\($0).mp4").path }
      try await Self.waitUntil {
        player.info.currentURL?.path == paths[0] && player.info.state == .paused && !player.info.pausedForLoading
          && player.mpv.getInt(MPVProperty.playlistCount) == 3
      }
      await Self.readPlaylist(of: player)
      #expect(player.info.playlist.map(\.filename) == paths)
      #expect(player.info.playlist.map(\.isCurrent) == [true, false, false])
    }
  }

  @Test("Files dropped on the window open in the player, and a dropped subtitle file is loaded in their place")
  func drops() async throws {
    try await Self.withPlayer { player, folder in
      let videos = ["a", "c"].map { folder.appendingPathComponent("\($0).mp4") }
      #expect(player.openFromPasteboard(FileDrop(videos)))
      try await Self.waitUntil {
        player.info.currentURL?.path == videos[0].path && player.info.state == .paused && !player.info.pausedForLoading
          && player.mpv.getInt(MPVProperty.playlistCount) == 2
      }
      // A subtitle file is not a playable file, so none is opened and the subtitle file is loaded instead.
      let subtitle = folder.appendingPathComponent("a.srt")
      try "1\n00:00:00,000 --> 00:00:01,000\nIINA\n".write(to: subtitle, atomically: true, encoding: .utf8)
      #expect(player.openFromPasteboard(FileDrop([subtitle])))
      try await Self.waitUntil { player.info.subTracks.contains { $0.externalFilename == subtitle.path } }
      #expect(player.info.currentURL?.path == videos[0].path)
      #expect(player.openFromPasteboard(FileDrop([videos[1]])))
      try await Self.waitUntil {
        player.info.currentURL?.path == videos[1].path && player.info.state == .paused && !player.info.pausedForLoading
      }
    }
  }

  @Test("Files opened in windows of their own each open in a player of their own, and a file already open is not opened again")
  func openInOwnWindows() async throws {
    try await Self.withPlayer { _, folder in
      try await Self.withSettings([.alwaysOpenInNewWindow: true, .groupSimultaneousOpensInPlaylist: false,
                                   .allowDuplicatePlayers: false]) {
        let videos = ["a", "c"].map { folder.appendingPathComponent("\($0).mp4") }
        #expect(await Self.open(videos) == 2)
        let players = try await Self.players(showing: videos.map(\.path))
        #expect(players[0] !== players[1])
        // The player showing the file is brought forward instead.
        #expect(await Self.open([videos[0]]) == nil)
        #expect(PlayerCore.playerCores.filter { $0.info.currentURL?.path == videos[0].path }.count == 1)
        try await Self.close(players)
      }
    }
  }

  @Test("A file asked twice at once to open in windows of its own opens in one player")
  func openTwiceInOwnWindows() async throws {
    try await Self.withPlayer { _, folder in
      try await Self.withSettings([.alwaysOpenInNewWindow: true, .groupSimultaneousOpensInPlaylist: false,
                                   .allowDuplicatePlayers: false]) {
        let video = folder.appendingPathComponent("c.mp4")
        // The second url is handed out while the first open is still finding its files, so no player shows it yet.
        #expect(await Self.open([video, video]) == 1)
        let players = try await Self.players(showing: [video.path])
        #expect(PlayerCore.playerCores.filter { $0.info.currentURL?.path == video.path }.count == 1)
        try await Self.close(players)
      }
    }
  }

  @Test("Files dropped with the app's open routing open together in a new player when the settings group them")
  func dropGrouped() async throws {
    try await Self.withPlayer { player, folder in
      try await Self.withSettings([.alwaysOpenInNewWindow: true, .groupSimultaneousOpensInPlaylist: true]) {
        let videos = ["a", "c"].map { folder.appendingPathComponent("\($0).mp4") }
        #expect(player.openFromPasteboard(FileDrop(videos), useGlobalOpenRouting: true))
        let players = try await Self.players(showing: [videos[0].path])
        #expect(players[0] !== player)
        #expect(players[0].mpv.getInt(MPVProperty.playlistCount) == 2)
        try await Self.close(players)
      }
    }
  }

  @Test("A file the system asks the app to open is opened in a player")
  func systemOpen() async throws {
    try await Self.withPlayer { _, folder in
      try await Self.withSettings([.alwaysOpenInNewWindow: true]) {
        let video = folder.appendingPathComponent("c.mp4")
        #expect(AppDelegate.shared.application(NSApp, openFile: video.path))
        let players = try await Self.players(showing: [video.path])
        try await Self.close(players)
      }
    }
  }

  @Test("Opening nothing reports nothing opened, a file opened without auto loading turns it off, and a playlist file is left to mpv")
  func openKinds() async throws {
    try await Self.withPlayer { player, folder in
      var counts: [Int?] = []
      player.openURLs([]) { counts.append($0) }
      #expect(counts == [0])
      let video = folder.appendingPathComponent("a.mp4")
      player.openURLs([video], shouldAutoLoad: false) { counts.append($0) }
      try await Self.waitUntil {
        player.info.currentURL?.path == video.path && player.info.state == .paused && !player.info.pausedForLoading
      }
      #expect(counts == [0, 1])
      #expect(!player.info.shouldAutoLoadFiles)
      // A cue sheet is a playlist file, whose entries mpv reads itself.
      let cue = folder.appendingPathComponent("b.cue")
      try "FILE \"b.mp4\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n".write(to: cue, atomically: true, encoding: .utf8)
      player.openURLs([cue]) { counts.append($0) }
      try await Self.waitUntil {
        player.info.currentURL?.path == cue.path && player.info.state == .paused && !player.info.pausedForLoading
      }
      #expect(counts == [0, 1, nil])
      #expect(!player.info.shouldAutoLoadFiles)
    }
  }

  @Test("Files opened in the current window open in the active player")
  func openInActiveWindow() async throws {
    try await Self.withPlayer { player, folder in
      try await Self.withSettings([.alwaysOpenInNewWindow: false]) {
        let video = folder.appendingPathComponent("c.mp4")
        let target = PlayerCore.activeOrNew
        #expect(await Self.open([video]) == 1)
        try await Self.waitUntil {
          target.info.currentURL?.path == video.path && target.info.state == .paused && !target.info.pausedForLoading
        }
        if target !== player {
          try await Self.close([target])
        }
      }
    }
  }

  @Test("Files added to the playlist at an index, past its end and at its end are added in requests that return before mpv handles them")
  func addToPlaylistDoesNotWait() async throws {
    try await Self.withPlayer { player, folder in
      let path = { (name: String) in folder.appendingPathComponent("\(name).mp4").path }
      let adds: [(name: String, add: () -> Void)] = [
        ("at an index", { player.addToPlaylist(paths: [path("d"), path("e")], at: 1) }),
        ("past the end", { player.addToPlaylist(paths: [path("f")], at: 99) }),
        ("at the end", { player.addToPlaylist(paths: [path("g")]) }),
      ]
      for (name, add) in adds {
        let returnedWhileHeld = try await Self.returnsWhileHeld(player, add)
        #expect(returnedWhileHeld, "Adding files \(name) waited for mpv")
      }
      try await Self.waitUntil { player.mpv.getInt(MPVProperty.playlistCount) == 7 }
      await Self.readPlaylist(of: player)
      #expect(player.info.playlist.map(\.filename) == ["a", "d", "e", "b", "c", "f", "g"].map(path))
    }
  }

  @Test("A file opened with Repeat on is opened, and its loop set, without waiting for mpv")
  func openWithRepeatDoesNotWait() async throws {
    try await Self.withPlayer { player, folder in
      try await Self.withSettings([.autoRepeat: true, .defaultRepeatMode: Preference.DefaultRepeatMode.playlist.rawValue]) {
        let hold = try MPVCoreHold(player.mpv, limit: Self.holdLimit)
        var openedWhileHeld: Bool?
        player.openURLs([folder.appendingPathComponent("c.mp4")], shouldAutoLoad: false) { _ in openedWhileHeld = !hold.hasLetGo }
        try await Self.waitUntil { openedWhileHeld != nil }
        hold.release()
        try await Self.waitUntil { hold.hasLetGo }
        #expect(openedWhileHeld == true, "Opening a file with Repeat on waited for mpv")
        try await Self.waitUntil { player.mpv.getString(MPVOption.PlaybackControl.loopPlaylist) == "inf" }
        #expect(player.mpv.getString(MPVOption.PlaybackControl.loopFile) == "no")
      }
    }
  }

  /// Read the properties of the file the player has loaded, as MPVController does when mpv reports it loaded. The test reads them
  /// on the main thread, where nothing holds mpv's core.
  private static func readLoadedFile(of player: PlayerCore) -> PlayerCore.LoadedFile {
    player.readLoadedFile()
  }

  /// `read` with one chapter and A-B loop points that mpv does not hold.
  private static func withChapterAndLoop(_ read: PlayerCore.LoadedFile) -> PlayerCore.LoadedFile {
    PlayerCore.LoadedFile(width: read.width, height: read.height, duration: read.duration, position: read.position,
                          remaining: read.remaining, path: read.path, mediaTitle: read.mediaTitle, trackList: read.trackList,
                          selectedTracks: read.selectedTracks,
                          chapters: [MPVChapter(title: "iinaTests", startTime: 1, index: 0)], abLoopA: 1, abLoopB: 2,
                          fullscreen: read.fullscreen, ontop: read.ontop)
  }

  @Test("A loaded file's tracks, chapters and A-B loop points are stored as they were read when mpv reported it loaded")
  func fileLoadedStoresWhatWasRead() async throws {
    try await Self.withPlayer { player, _ in
      let read = Self.readLoadedFile(of: player)
      #expect(read.trackList.video.map(\.id) == player.info.videoTracks.map(\.id))
      #expect(read.selectedTracks.vid == player.info.vid)
      // A chapter and loop points mpv does not hold show that fileLoaded stores what it is given instead of asking mpv.
      player.fileLoaded(Self.withChapterAndLoop(read))
      #expect(player.info.chapters.map(\.title) == ["iinaTests"])
      #expect(player.info.abLoopStatus == .bSet)
      #expect(player.info.videoTracks.map(\.id) == read.trackList.video.map(\.id))
    }
  }

  /// `read` with the window floating on top, which mpv does not hold.
  private static func onTop(_ read: PlayerCore.LoadedFile) -> PlayerCore.LoadedFile {
    PlayerCore.LoadedFile(width: read.width, height: read.height, duration: read.duration, position: read.position,
                          remaining: read.remaining, path: read.path, mediaTitle: read.mediaTitle, trackList: read.trackList,
                          selectedTracks: read.selectedTracks, chapters: read.chapters, abLoopA: read.abLoopA,
                          abLoopB: read.abLoopB, fullscreen: read.fullscreen, ontop: true)
  }

  @Test("A loaded file is stored without waiting for mpv, the window taking the on-top state read when mpv reported it loaded")
  func fileLoadedDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      let read = Self.readLoadedFile(of: player)
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.fileLoaded(Self.onTop(read)) }
      #expect(returnedWhileHeld, "Storing a loaded file waited for mpv")
      // An on-top state mpv does not hold shows that the window takes the state it is given instead of asking mpv.
      try await Self.waitUntil { player.mainWindow.window?.level == .iinaFloating }
      player.mainWindow.setWindowFloatingOnTop(false, updateOnTopStatus: false)
    }
  }

  @Test("A loaded file reported once the player is no longer active is ignored")
  func fileLoadedWhenInactive() async throws {
    try await Self.withPlayer { player, _ in
      let read = Self.readLoadedFile(of: player)
      player.mainWindow.close()
      try await Self.waitUntil { player.info.state == .idle }
      player.fileLoaded(Self.withChapterAndLoop(read))
      #expect(player.info.state == .idle)
      #expect(player.info.chapters.isEmpty)
      #expect(player.info.abLoopStatus == .cleared)
    }
  }

  @Test("A change of the audio track is stored without waiting for mpv, taking the track id mpv reported in the change")
  func aidChangedDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      // A track id mpv does not hold shows that the player stores the id it is given instead of asking mpv.
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.aidChanged(7) }
      #expect(returnedWhileHeld, "Storing a change of the audio track waited for mpv")
      #expect(player.info.aid == 7)
      #expect(player.mainWindow.muteButton.isHidden == false)
    }
  }

  @Test("A change of the subtitle track is stored without waiting for mpv, taking the track id mpv reported in the change")
  func sidChangedDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      var notified = false
      player.observe(.iinaSIDChanged) { _ in notified = true }
      // A track id mpv does not hold shows that the player stores the id it is given instead of asking mpv.
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.sidChanged(7) }
      #expect(returnedWhileHeld, "Storing a change of the subtitle track waited for mpv")
      #expect(player.info.sid == 7)
      #expect(notified)
    }
  }

  @Test("A change of the chapter is stored without waiting for mpv, taking the chapter mpv reported in the change")
  func chapterChangedDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      var notified = false
      player.observe(.iinaChapterListChanged) { _ in notified = true }
      // A chapter the file does not have shows that the player stores the chapter it is given instead of asking mpv.
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.chapterChanged(7) }
      #expect(returnedWhileHeld, "Storing a change of the chapter waited for mpv")
      #expect(player.info.chapter == 7)
      #expect(notified)
    }
  }

  @Test("A change of the on-top state is applied without waiting for mpv, the window taking the state mpv reported in the change")
  func ontopChangedDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      // An on-top state mpv does not hold shows that the window takes the state it is given instead of asking mpv.
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.ontopChanged(true) }
      #expect(returnedWhileHeld, "Applying a change of the on-top state waited for mpv")
      try await Self.waitUntil { player.mainWindow.window?.level == .iinaFloating }
      player.mainWindow.setWindowFloatingOnTop(false, updateOnTopStatus: false)
    }
  }

  @Test("Putting the window on top asks mpv to set ontop without waiting for it")
  func ontopSetDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.mainWindow.isOntop = true }
      #expect(returnedWhileHeld, "Putting the window on top waited for mpv")
      #expect(await Self.ontop(player) == true)
      player.mainWindow.isOntop = false
    }
  }

  /// Ask `mpv` whether the window is on top and wait for the answer, which comes after its answers to every request made before.
  private static func ontop(_ player: PlayerCore) async -> Bool? {
    await withCheckedContinuation { continuation in
      player.mpv.getFlagAsync(MPVOption.Window.ontop) { continuation.resume(returning: $0) }
    }
  }

  @Test("Selecting a track asks mpv without waiting for it, the track mpv selects being stored when it reports the change")
  func setTrackDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      try await Self.waitUntil { player.info.vid == 1 }
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.setTrack(0, forType: .video) }
      #expect(returnedWhileHeld, "Selecting a track waited for mpv")
      try await Self.waitUntil { player.info.vid == 0 }
    }
  }

  @Test("A change of the video track is stored without waiting for mpv, taking the track id mpv reported in the change")
  func vidChangedDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      var notified = false
      player.observe(.iinaVIDChanged) { _ in notified = true }
      // A track id mpv does not hold shows that the player stores the id it is given instead of asking mpv.
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.vidChanged(7) }
      #expect(returnedWhileHeld, "Storing a change of the video track waited for mpv")
      #expect(player.info.vid == 7)
      #expect(notified)
    }
  }

  @Test("A change of the secondary subtitle track is stored without waiting for mpv, taking the track id mpv reported in the change")
  func secondarySidChangedDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      var notified = false
      player.observe(.iinaSIDChanged) { _ in notified = true }
      // A track id mpv does not hold shows that the player stores the id it is given instead of asking mpv.
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.secondarySidChanged(7) }
      #expect(returnedWhileHeld, "Storing a change of the secondary subtitle track waited for mpv")
      #expect(player.info.secondSid == 7)
      #expect(notified)
    }
  }

  @Test("Toggling the loops asks mpv without waiting for it, and the loop mode read before mpv sets the loop is the one asked for")
  func loopModeDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      let toggles: [(name: String, toggle: () -> Void, mode: LoopMode, file: String, playlist: String)] = [
        ("the playlist loop", { player.togglePlaylistLoop() }, .playlist, "no", "inf"),
        ("the file loop", { player.toggleFileLoop() }, .file, "inf", "inf"),
        ("to the loop mode after the file loop", { player.nextLoopMode() }, .playlist, "no", "inf"),
        ("to the loop mode after the playlist loop", { player.nextLoopMode() }, .off, "no", "no"),
      ]
      for (name, toggle, mode, file, playlist) in toggles {
        let hold = try MPVCoreHold(player.mpv, limit: Self.holdLimit)
        toggle()
        let returnedWhileHeld = !hold.hasLetGo
        let modeWhileHeld = player.getLoopMode()
        hold.release()
        try await Self.waitUntil { hold.hasLetGo }
        #expect(returnedWhileHeld, "Toggling \(name) waited for mpv")
        #expect(modeWhileHeld == mode, "Toggling \(name)")
        try await Self.waitUntil {
          player.mpv.getString(MPVOption.PlaybackControl.loopFile) == file
            && player.mpv.getString(MPVOption.PlaybackControl.loopPlaylist) == playlist
        }
      }
    }
  }

  @Test("A change of loop-file is stored without waiting for mpv, taking the value mpv reported in the change")
  func loopOptionChangedDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      var notified = false
      player.observe(.iinaLoopStatusChanged) { _ in notified = true }
      // A value mpv does not hold shows that the player stores the value it is given instead of asking mpv.
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) {
        player.loopOptionChanged(MPVOption.PlaybackControl.loopFile, "inf")
      }
      #expect(returnedWhileHeld, "Storing a change of loop-file waited for mpv")
      #expect(player.getLoopMode() == .file)
      #expect(notified)
    }
  }

  @Test("The A-B loop command and a move of its A point return before mpv handles them, the loop points mpv answers being stored")
  func abLoopDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      player.seek(absoluteSecond: 1)
      try await Self.waitForPosition(1, of: player)
      var answered: (a: Double, b: Double)?
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.abLoop { answered = ($0, $1) } }
      #expect(returnedWhileHeld, "The A-B loop command waited for mpv")
      try await Self.waitUntil { answered != nil }
      #expect(player.info.abLoopStatus == .aSet)
      #expect(abs((answered?.a ?? 0) - 1) < 0.11)
      #expect(answered?.b == 0)
      let movedWhileHeld = try await Self.returnsWhileHeld(player) { player.abLoopA = 2 }
      #expect(movedWhileHeld, "Moving the A loop point waited for mpv")
      try await Self.waitUntil { player.mpv.getDouble(MPVOption.PlaybackControl.abLoopA) == 2 }
    }
  }

  @Test("Reloading the subtitles returns before mpv handles it, the track list mpv answers after the reloads being stored")
  func reloadAllSubsDoesNotWait() async throws {
    try await Self.withPlayer { player, folder in
      let subtitle = folder.appendingPathComponent("b.srt")
      try "1\n00:00:00,000 --> 00:00:04,000\nSubtitle\n".write(to: subtitle, atomically: true, encoding: .utf8)
      player.loadExternalSubFile(subtitle)
      try await Self.waitUntil { player.info.subTracks.count == 1 }
      // A track list mpv does not hold shows that the player stores the list mpv answers.
      player.info.videoTracks = []
      var stored = false
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.reloadAllSubs { stored = true } }
      #expect(returnedWhileHeld, "Reloading the subtitles waited for mpv")
      try await Self.waitUntil { stored }
      #expect(player.info.videoTracks.count == 1)
      #expect(player.info.subTracks.count == 1)
    }
  }

  @Test("The chapter list is read again without waiting for mpv, the list mpv answers being stored")
  func reloadChaptersDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      var notified = false
      player.observe(.iinaChapterListChanged) { _ in notified = true }
      // A chapter the file does not have shows that the player stores the list mpv answers.
      player.info.chapters = [MPVChapter(title: "Not in the file", startTime: 1, index: 0)]
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.reloadChapters() }
      #expect(returnedWhileHeld, "Reading the chapter list again waited for mpv")
      try await Self.waitUntil { notified }
      #expect(player.info.chapters.map(\.title) == player.readChapters().map(\.title))
    }
  }

  @Test("Playlist edits other than adding files return before mpv handles them, mpv making them in the order they are asked")
  func playlistEditsDoNotWait() async throws {
    try await Self.withPlayer { player, folder in
      let path = { (name: String) in folder.appendingPathComponent("\(name).mp4").path }
      let edits: [(name: String, edit: () -> Void, playlist: [String])] = [
        ("appending a file", { player.appendToPlaylist(path("d")) }, ["a", "b", "c", "d"]),
        ("moving an entry", { player.playlistMove(3, to: 0) }, ["d", "a", "b", "c"]),
        ("removing an entry", { player.playlistRemove(0) }, ["a", "b", "c"]),
        ("removing entries", {
          player.appendToPlaylist(path("e"))
          player.appendToPlaylist(path("f"))
          player.playlistRemove(IndexSet([3, 4]))
        }, ["a", "b", "c"]),
        ("reordering the playlist", { player.playlistReorder(newPlaylist: player.info.playlist.reversed()) }, ["c", "b", "a"]),
        ("clearing the playlist", { player.clearPlaylist() }, ["b"]),
      ]
      for (name, edit, playlist) in edits {
        await Self.readPlaylist(of: player)
        let returnedWhileHeld = try await Self.returnsWhileHeld(player, edit)
        #expect(returnedWhileHeld, "Playlist edit \(name) waited for mpv")
        await Self.readPlaylist(of: player)
        #expect(player.info.playlist.map(\.filename) == playlist.map(path), "After \(name)")
      }
    }
  }

  @Test("A drag of a folder is answered from its name, without the main thread reading the folder")
  func dragAnsweredByName() async throws {
    try await Self.withPlayer { player, folder in
      // Read, an empty folder holds nothing that can be opened, so a drag answered from what the folder holds is refused.
      let empty = folder.appendingPathComponent("empty")
      try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
      #expect(player.acceptFromPasteboard(FileDrop([empty])) == .copy)
      #expect(player.acceptFromPasteboard(FileDrop([empty]), isPlaylist: true) == .copy)
      #expect(player.acceptFromPasteboard(FileDrop([folder.appendingPathComponent("b.srt")]), isPlaylist: true) == [])
    }
  }

  @Test("Dropped files are made into URLs off the main thread: the drop returns while the queue doing it is held, before any open has begun")
  func dropDoesNotReadOnMain() async throws {
    try await Self.withPlayer { player, folder in
      let held = DispatchSemaphore(value: 0)
      player.openQueue.async { held.wait() }
      let video = folder.appendingPathComponent("c.mp4")
      #expect(player.openFromPasteboard(FileDrop([video])))
      // Making the dropped paths into URLs reads the filesystem and is left to the held queue, so no open has begun.
      #expect(player.opensFindingFiles.isEmpty)
      held.signal()
      try await Self.waitUntil {
        player.info.currentURL?.path == video.path && player.info.state == .paused && !player.info.pausedForLoading
      }
    }
  }

  @Test("A 3D LUT file and a subtitle file dropped alone are added in requests that return before mpv handles them")
  func dropsDoNotWait() async throws {
    // Hardware decoding is off from the start: adding a filter while it is set to auto asks the user first, and turning it off later
    // reconfigures the video while the core is held.
    try await Self.withSettings([.hardwareDecoder: Preference.HardwareDecoderOption.disabled.rawValue]) {
      try await Self.withPlayer { player, folder in
        player.syncUITimer?.invalidate()
        let lut = folder.appendingPathComponent("look.cube")
        // The identity 3D LUT of size 2, red changing fastest.
        let lattice = (0..<8).map { "\($0 & 1) \(($0 >> 1) & 1) \(($0 >> 2) & 1)" }
        try (["LUT_3D_SIZE 2"] + lattice).joined(separator: "\n").write(to: lut, atomically: true, encoding: .utf8)
        let lutAddedWhileHeld = try await Self.dropRequestsWhileHeld(player, [lut])
        #expect(lutAddedWhileHeld, "Adding the dropped 3D LUT file waited for mpv")
        try await Self.waitUntil { player.mpv.getFilters(MPVProperty.vf).contains { $0.label == "iina_quickl3d" } }
        let subtitle = folder.appendingPathComponent("b.srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nIINA\n".write(to: subtitle, atomically: true, encoding: .utf8)
        let subtitleAddedWhileHeld = try await Self.dropRequestsWhileHeld(player, [subtitle])
        #expect(subtitleAddedWhileHeld, "Loading the dropped subtitle file waited for mpv")
        try await Self.waitUntil { player.info.subTracks.contains { $0.externalFilename == subtitle.path } }
      }
    }
  }

  @Test("A video reconfig mpv reports is handled on the main thread without waiting for mpv, storing the display size read with it")
  func videoReconfigDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      player.syncUITimer?.invalidate()
      let width = try #require(player.info.displayWidth)
      let height = try #require(player.info.displayHeight)
      let reconfig = PlayerCore.VideoReconfig(dwidth: width * 2, dheight: height * 2,
                                              videoParamsRotation: player.info.videoParamsRotation,
                                              rotation: player.info.rotation, coreIdle: false)
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.onVideoReconfig(reconfig) }
      #expect(returnedWhileHeld, "Handling the video reconfig waited for mpv")
      #expect(player.info.displayWidth == width * 2)
      #expect(player.info.displayHeight == height * 2)
      // A filter that scales the video makes mpv report a reconfig, whose display size is read on the queue for reading mpv events.
      // The test file is 4:3, so its display size is the size it is scaled to.
      player.mpv.command(.vf, args: ["add", "scale=320:240"])
      try await Self.waitUntil { player.info.displayWidth == 320 && player.info.displayHeight == 240 }
    }
  }

  @Test("The mpv options given on the command line are set in requests that return before mpv handles them")
  func commandLineOptionsDoNotWait() async throws {
    try await Self.withPlayer { player, _ in
      player.syncUITimer?.invalidate()
      var status = CommandLineStatus()
      status.mpvArguments = [(MPVOption.PlaybackControl.speed, "1.5"), (MPVOption.Audio.volume, "40")]
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { status.applyMPVArguments(to: player) }
      #expect(returnedWhileHeld, "Setting the command-line options waited for mpv")
      try await Self.waitUntil { player.info.playSpeed == 1.5 && player.info.volume == 40 }
    }
  }

  @Test("Files the system asks the app to open are made into file URLs off the main thread, then opened")
  func systemOpenDoesNotReadOnMain() async throws {
    try await Self.withPlayer { _, folder in
      try await Self.withSettings([.alwaysOpenInNewWindow: true]) {
        let held = DispatchSemaphore(value: 0)
        AppDelegate.shared.openQueue.async { held.wait() }
        let video = folder.appendingPathComponent("c.mp4")
        AppDelegate.shared.openFiles([video.path])
        // Making the path into a file URL reads the filesystem and is left to the held queue, so no player has begun opening it when
        // openFiles returns. Made on main, the URL would be handed at once to a new player, which would be finding its files.
        #expect(PlayerCore.playerCores.allSatisfy { $0.opensFindingFiles.isEmpty })
        held.signal()
        let players = try await Self.players(showing: [video.path])
        try await Self.close(players)
      }
    }
  }

  @Test("The position is synchronized, while the time is not kept up to date, in a request that returns before mpv handles it")
  func positionSyncDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      player.seek(percent: 50, forceExact: true)
      try await Self.waitForPosition(2, of: player)
      player.syncUITimer?.invalidate()
      var synced = false
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.syncPositionIfNeeded { synced = true } }
      #expect(returnedWhileHeld, "Synchronizing the position waited for mpv")
      try await Self.waitUntil { synced }
      #expect(abs((player.info.videoPosition?.second ?? 0) - 2) < 0.11)
    }
  }

  @Test("The position is not asked of mpv while the time is kept up to date")
  func positionSyncWhileTimed() async throws {
    try await Self.withPlayer { player, _ in
      let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in }
      player.syncUITimer = timer
      defer { timer.invalidate() }
      var synced = false
      let waiting = player.mpv.replyCallbacks.count
      player.syncPositionIfNeeded { synced = true }
      #expect(synced)
      #expect(player.mpv.replyCallbacks.count == waiting)
    }
  }

  @Test("The position sync the JavaScript status waits on stores the position mpv answers while the time is not kept up to date, and asks nothing while it is")
  func positionSyncWaiting() async throws {
    try await Self.withPlayer { player, _ in
      player.seek(percent: 50, forceExact: true)
      try await Self.waitForPosition(2, of: player)
      let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in }
      player.syncUITimer = timer
      // A position mpv does not hold shows whether the sync stores what mpv answers.
      player.info.videoPosition = VideoTime(0)
      player.syncPositionIfNeededWaiting()
      #expect(player.info.videoPosition?.second == 0)
      timer.invalidate()
      player.syncPositionIfNeededWaiting()
      #expect(abs((player.info.videoPosition?.second ?? 0) - 2) < 0.11)
    }
  }

  @Test("The waiting position sync asks nothing of mpv for a player no longer active")
  func positionSyncWaitingInactive() async throws {
    try await Self.withPlayer { player, _ in
      player.mainWindow.close()
      try await Self.waitUntil { player.info.state == .idle }
      player.syncUITimer?.invalidate()
      player.info.videoPosition = VideoTime(1)
      player.syncPositionIfNeededWaiting()
      #expect(player.info.videoPosition?.second == 1)
    }
  }

  @Test("For a stream read over the network the waiting position sync also stores the duration mpv answers")
  func positionSyncWaitingNetwork() async throws {
    try await Self.withPlayer { player, folder in
      let server = try await LocalStreamServer(serving: folder.appendingPathComponent("a.mp4"))
      defer { server.stop() }
      player.addToPlaylist(paths: [server.url.absoluteString])
      try await Self.waitUntil { player.mpv.getInt(MPVProperty.playlistCount) == 4 }
      player.playFileInPlaylist(3)
      try await Self.waitForEntry(3, of: player)
      #expect(player.info.isNetworkResource)
      // Once mpv has read the whole stream, the duration it answers stays as it is.
      try await Self.waitUntil { player.mpv.getFlag(MPVProperty.demuxerCacheIdle) }
      player.syncUITimer?.invalidate()
      player.info.videoDuration = VideoTime(-1)
      player.syncPositionIfNeededWaiting()
      #expect(player.info.videoDuration?.second == player.mpv.getDouble(MPVProperty.duration))
    }
  }

  @Test("A time sync without a completion is skipped while an earlier one awaits mpv's answer")
  func timeSyncPending() async throws {
    try await Self.withPlayer { player, _ in
      let hold = try MPVCoreHold(player.mpv, limit: Self.holdLimit)
      var synced = false
      player.syncTime { synced = true }
      let waiting = player.mpv.replyCallbacks.count
      player.syncTime()
      #expect(player.mpv.replyCallbacks.count == waiting)
      hold.release()
      try await Self.waitUntil { hold.hasLetGo && synced }
    }
  }

  @Test("At the end of the last file the time sync stores the duration as the position")
  func timeSyncAtEnd() async throws {
    try await Self.withPlayer { player, _ in
      player.playFileInPlaylist(2)
      try await Self.waitForEntry(2, of: player)
      player.seek(absoluteSecond: 3.5)
      try await Self.waitForPosition(3.5, of: player)
      player.mpv.setFlagAsync(MPVOption.PlaybackControl.pause, false)
      try await Self.waitUntil { player.mpv.getFlag(MPVProperty.eofReached) }
      var synced = false
      player.syncTime { synced = true }
      try await Self.waitUntil { synced }
      let duration = try #require(player.info.videoDuration?.second)
      #expect(player.info.videoPosition?.second == duration)
    }
  }

  @Test("The remaining time is worked out from the full length once it is known, and read from mpv before")
  func timeSyncRemaining() async throws {
    try await Self.withPlayer { player, _ in
      player.seek(percent: 50, forceExact: true)
      try await Self.waitForPosition(2, of: player)
      try await Self.waitUntil { player.info.fullLength != nil }
      var synced = false
      player.syncTime { synced = true }
      try await Self.waitUntil { synced }
      let fullLength = try #require(player.info.fullLength)
      #expect(abs((player.info.videoRemaining?.second ?? 0) - (fullLength - 2)) < 0.11)
      player.info.fullLength = nil
      synced = false
      player.syncTime { synced = true }
      try await Self.waitUntil { synced }
      #expect(abs((player.info.videoRemaining?.second ?? 0) - player.mpv.getDouble(MPVProperty.timeRemainingFull)) < 0.11)
    }
  }

  @Test("A drop none of whose files can be opened, judged by their extensions, is refused, and a playlist file dropped alone opens")
  func dropRefusedOrPlaylist() async throws {
    try await Self.withPlayer { player, folder in
      let playlists = ["x", "y"].map { folder.appendingPathComponent("\($0).m3u") }
      for playlist in playlists {
        try "".write(to: playlist, atomically: true, encoding: .utf8)
      }
      #expect(!player.openFromPasteboard(FileDrop(playlists)))
      let cue = folder.appendingPathComponent("b.cue")
      try "FILE \"b.mp4\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n".write(to: cue, atomically: true, encoding: .utf8)
      #expect(player.openFromPasteboard(FileDrop([cue])))
      try await Self.waitUntil {
        player.info.currentURL?.path == cue.path && player.info.state == .paused && !player.info.pausedForLoading
      }
    }
  }

  @Test("The OSD of a seek shows the position mpv answers once it has handled the seek")
  func seekOSDShowsAnsweredPosition() async throws {
    try await Self.withPlayer { player, _ in
      try await Self.withSettings([.enableOSD: true]) {
        // The OSD is turned off while a file loads, until shortly after its playback starts.
        try await Self.waitUntil { !player.info.disableOSDForFileLoading }
        let label = try #require(player.mainWindow.osdView?.label)
        let seeks: [(name: String, seek: () -> Void, landing: Double)] = [
          ("by seconds", { player.seek(relativeSecond: 2.25, option: .exact) }, 2.25),
          ("to the start", { player.seekToStart() }, 0),
        ]
        for (name, seek, landing) in seeks {
          label.stringValue = ""
          seek()
          try await Self.waitUntil { !label.stringValue.isEmpty }
          // A seek's OSD shows the position, then the duration.
          #expect(label.stringValue.hasPrefix(VideoTime(landing).stringRepresentation + " / "),
                  "The OSD of the \(name) seek showed \(label.stringValue)")
          try await Self.waitForPosition(landing, of: player)
        }
      }
    }
  }

  @Test("For a stream read over the network the time sync also stores the duration and cache state mpv answers")
  func timeSyncNetwork() async throws {
    try await Self.withPlayer { player, folder in
      let server = try await LocalStreamServer(serving: folder.appendingPathComponent("a.mp4"))
      defer { server.stop() }
      player.addToPlaylist(paths: [server.url.absoluteString])
      try await Self.waitUntil { player.mpv.getInt(MPVProperty.playlistCount) == 4 }
      player.playFileInPlaylist(3)
      try await Self.waitForEntry(3, of: player)
      #expect(player.info.isNetworkResource)
      // Once mpv has read the whole stream, the values it answers stay as they are.
      try await Self.waitUntil { player.mpv.getFlag(MPVProperty.demuxerCacheIdle) }
      // Values mpv does not hold show that the sync stores what mpv answers.
      player.info.videoDuration = VideoTime(-1)
      player.info.pausedForCache = true
      player.info.cacheTime = -1
      player.info.bufferingState = -1
      var synced = false
      player.syncTime { synced = true }
      try await Self.waitUntil { synced }
      #expect(player.info.videoDuration?.second == player.mpv.getDouble(MPVProperty.duration))
      #expect(!player.info.pausedForCache)
      #expect(player.info.cacheTime == Int(player.mpv.getDouble(MPVProperty.demuxerCacheTime)))
      #expect(player.info.bufferingState == player.mpv.getInt(MPVProperty.cacheBufferingState))
    }
  }

  /// A setting a player, or a menu item of its window, asks `mpv` for: each is a site that must not wait for `mpv` on the main thread.
  enum SettingRequest: String, CaseIterable, Sendable {
    case mute, volume, speed, aspect, rotation, deinterlace, hardwareDecoding, equalizer, audioDelay, subDelay, secondSubDelay
    case subVisibility, secondSubVisibility, subScale, subPos, secondSubPos, subColor, subFontSize, subBold, subOutlineColor
    case subOutlineSize, subBackColor, subEncoding, subFont, audioDevice, frameStep, shuffle, externalVideo, chapter
    case menuSpeed, menuVolume, menuMute, menuAudioDelay, menuResetAudioDelay, menuSubDelay, menuResetSubDelay, menuSubScale
    case menuDeinterlace, menuAspect, menuRotation, menuSubVisibility, menuSecondSubVisibility, menuStepFrame, menuNextChapter
    case menuPreviousChapter, menuCycleVideo
  }

  @Test("Each setting a player or its window's menu asks of mpv is asked in a request that returns before mpv handles it",
        arguments: SettingRequest.allCases)
  func settingDoesNotWait(_ request: SettingRequest) async throws {
    try await Self.withPlayer { player, folder in
      player.syncUITimer?.invalidate()
      let mpv: MPVController = player.mpv
      let handler = MainMenuActionHandler(playerCore: player)
      func item(_ representedObject: Any? = nil, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = representedObject
        item.tag = tag
        return item
      }
      func color(_ name: String) -> String? { mpv.getString("options/" + name) }
      let before = (position: mpv.getDouble(MPVProperty.timePos), subColor: color(MPVOption.Subtitles.subColor),
                    outlineColor: color(MPVOption.Subtitles.subOutlineColor), backColor: color(MPVOption.Subtitles.subBackColor),
                    videoTracks: player.info.videoTracks.count)
      let ask: () -> Void
      let applied: () -> Bool
      switch request {
      case .mute, .menuMute:
        ask = request == .mute ? { player.toggleMute() } : { handler.menuToggleMute(item()) }
        applied = { mpv.getFlag(MPVOption.Audio.mute) }
      case .volume, .menuVolume:
        // A step toward the middle of the range, so that the volume asked for is not clamped.
        let step = player.info.volume >= 50 ? -10 : 10
        let volume = player.info.volume + Double(step)
        ask = request == .volume ? { player.setVolume(volume) } : { handler.menuChangeVolume(item(step)) }
        applied = { mpv.getDouble(MPVOption.Audio.volume) == volume }
      case .speed, .menuSpeed:
        ask = request == .speed ? { player.setSpeed(2) } : { handler.menuChangeSpeed(item(2.0)) }
        applied = { mpv.getDouble(MPVOption.PlaybackControl.speed) == 2 }
      case .aspect, .menuAspect:
        ask = request == .aspect ? { player.setVideoAspect("16:9") } : { handler.menuChangeAspect(item("16:9")) }
        applied = { abs(mpv.getDouble(MPVOption.Video.videoAspectOverride) - 16 / 9) < 0.01 }
      case .rotation, .menuRotation:
        ask = request == .rotation ? { player.setVideoRotate(90) } : { handler.menuChangeRotation(item(90)) }
        applied = { mpv.getInt(MPVOption.Video.videoRotate) == 90 }
      case .deinterlace, .menuDeinterlace:
        ask = request == .deinterlace ? { player.toggleDeinterlace(true) } : { handler.menuToggleDeinterlace(item()) }
        applied = { mpv.getFlag(MPVOption.Video.deinterlace) }
      case .hardwareDecoding:
        ask = { player.toggleHardwareDecoding(false) }
        applied = { mpv.getString(MPVOption.Video.hwdec) == "no" }
      case .equalizer:
        ask = { player.setVideoEqualizer(forOption: .brightness, value: 10) }
        applied = { mpv.getInt(MPVOption.Equalizer.brightness) == 10 }
      case .audioDelay, .menuAudioDelay:
        ask = request == .audioDelay ? { player.setAudioDelay(0.5) } : { handler.menuChangeAudioDelay(item(0.5)) }
        applied = { mpv.getDouble(MPVOption.Audio.audioDelay) == 0.5 }
      case .menuResetAudioDelay:
        mpv.setDouble(MPVOption.Audio.audioDelay, 0.5)
        ask = { handler.menuResetAudioDelay(item()) }
        applied = { mpv.getDouble(MPVOption.Audio.audioDelay) == 0 }
      case .subDelay, .menuSubDelay:
        ask = request == .subDelay ? { player.setSubDelay(0.5) } : { handler.menuChangeSubDelay(item(0.5)) }
        applied = { mpv.getDouble(MPVOption.Subtitles.subDelay) == 0.5 }
      case .menuResetSubDelay:
        mpv.setDouble(MPVOption.Subtitles.subDelay, 0.5)
        ask = { handler.menuResetSubDelay(item()) }
        applied = { mpv.getDouble(MPVOption.Subtitles.subDelay) == 0 }
      case .secondSubDelay:
        ask = { player.setSubDelay(0.5, forPrimary: false) }
        applied = { mpv.getDouble(MPVOption.Subtitles.secondarySubDelay) == 0.5 }
      case .subVisibility, .menuSubVisibility:
        ask = request == .subVisibility ? { player.toggleSubVisibility(false) } : { handler.menuToggleSubVisibility(item()) }
        applied = { !mpv.getFlag(MPVOption.Subtitles.subVisibility) }
      case .secondSubVisibility, .menuSecondSubVisibility:
        ask = request == .secondSubVisibility ? { player.toggleSecondSubVisibility(false) }
          : { handler.menuToggleSecondSubVisibility(item()) }
        applied = { !mpv.getFlag(MPVOption.Subtitles.secondarySubVisibility) }
      case .subScale, .menuSubScale:
        ask = request == .subScale ? { player.setSubScale(1.1) } : { handler.menuChangeSubScale(item(tag: 1)) }
        applied = { abs(mpv.getDouble(MPVOption.Subtitles.subScale) - 1.1) < 0.001 }
      case .subPos:
        ask = { player.setSubPos(80) }
        applied = { mpv.getInt(MPVOption.Subtitles.subPos) == 80 }
      case .secondSubPos:
        ask = { player.setSubPos(80, forPrimary: false) }
        applied = { mpv.getInt(MPVOption.Subtitles.secondarySubPos) == 80 }
      case .subColor:
        ask = { player.setSubTextColor(NSColor.red.mpvColorString) }
        applied = { color(MPVOption.Subtitles.subColor) != before.subColor }
      case .subFontSize:
        ask = { player.setSubTextSize(60) }
        applied = { mpv.getDouble("options/" + MPVOption.Subtitles.subFontSize) == 60 }
      case .subBold:
        ask = { player.setSubTextBold(true) }
        applied = { mpv.getFlag("options/" + MPVOption.Subtitles.subBold) }
      case .subOutlineColor:
        ask = { player.setSubTextBorderColor(NSColor.red.mpvColorString) }
        applied = { color(MPVOption.Subtitles.subOutlineColor) != before.outlineColor }
      case .subOutlineSize:
        ask = { player.setSubTextBorderSize(4) }
        applied = { mpv.getDouble("options/" + MPVOption.Subtitles.subOutlineSize) == 4 }
      case .subBackColor:
        ask = { player.setSubTextBgColor(NSColor.red.mpvColorString) }
        applied = { color(MPVOption.Subtitles.subBackColor) != before.backColor }
      case .subEncoding:
        ask = { player.setSubEncoding("cp1252") }
        applied = { mpv.getString(MPVOption.Subtitles.subCodepage) == "cp1252" }
      case .subFont:
        ask = { player.setSubFont("Helvetica") }
        applied = { mpv.getString(MPVOption.Subtitles.subFont) == "Helvetica" }
      case .audioDevice:
        let device = player.getAudioDevices().last?.name ?? "auto"
        ask = { player.setAudioDevice(device) }
        applied = { mpv.getString(MPVProperty.audioDevice) == device }
      case .frameStep, .menuStepFrame:
        ask = request == .frameStep ? { player.frameStep(backwards: false) } : { handler.menuStepFrame(item(tag: 0)) }
        applied = { mpv.getDouble(MPVProperty.timePos) > before.position }
      case .shuffle:
        ask = { player.toggleShuffle() }
        applied = { player.info.isShuffled }
      case .externalVideo:
        ask = { player.loadExternalVideoFile(folder.appendingPathComponent("a.mp4")) }
        applied = { player.info.videoTracks.count > before.videoTracks }
      case .chapter:
        // The test files have no chapters, so the player is given one starting 2 s in, which playing the chapter seeks to.
        player.info.chapters = [MPVChapter(title: "iinaTests", startTime: 2, index: 0)]
        ask = { _ = player.playChapter(0) }
        applied = { mpv.getDouble(MPVProperty.timePos) >= 1.9 }
      case .menuNextChapter, .menuPreviousChapter:
        // The test files have no chapters, so mpv changes nothing; only that the request does not wait is checked.
        ask = request == .menuNextChapter ? { handler.menuNextChapter(item()) } : { handler.menuPreviousChapter(item()) }
        applied = { true }
      case .menuCycleVideo:
        ask = { handler.menuCycleTrack(item(tag: 0)) }
        applied = { mpv.getString(MPVOption.TrackSelection.vid) == "no" }
      }
      let returnedWhileHeld = try await Self.returnsWhileHeld(player, ask)
      #expect(returnedWhileHeld, "Asking for \(request) waited for mpv")
      try await Self.waitUntil(applied)
    }
  }

  /// Views made in a test that observe their player without keeping themselves, kept for as long as the player may notify them.
  private static var keptViews: [NSView] = []

  /// Keep `view` for as long as its player may notify it.
  private static func kept<View: NSView>(_ view: View) -> View {
    keptViews.append(view)
    return view
  }

  /// The views of type `T` under `view`, in the order of the view tree.
  private static func views<T: NSView>(_ type: T.Type, under view: NSView) -> [T] {
    view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, under: subview) }
  }

  /// The controls of type `T` under `view` that send the action named `action`, such as `"scaleAction:"`, to their target.
  private static func controls<T: NSControl>(_ type: T.Type, sending action: String, under view: NSView) -> [T] {
    views(type, under: view).filter { $0.action == NSSelectorFromString(action) }
  }

  /// The slider view under `view` that is updated when the player posts `name`.
  private static func sliderView(notifiedBy name: Notification.Name, under view: NSView) throws -> SidebarSliderView {
    try #require(views(SidebarSliderView.self, under: view).first(where: { $0.notificationKey == name }))
  }

  /// Send the action of `control` to its target, as a click on it does.
  private static func send(_ control: NSControl) {
    _ = control.sendAction(control.action, to: control.target)
  }

  /// A control of a player's window, sidebar or menu that asks `mpv` for a setting, or a view that shows a setting: each is a site
  /// that must not wait for `mpv` on the main thread.
  enum ControlRequest: String, CaseIterable, Sendable {
    case menuAudioDevice, playButton, arrowButton, volumeSlider, muteButton, shuffleButton, subVisibilitySwitch
    case secondSubVisibilitySwitch, subPosSlider, subScaleReset, subScaleSlider, subFontSizePicker, subBorderSizePicker
    case subTextColorWell, subBackColorWell, subBorderColorWell, aspectSegment, rotationSegment, hwdecSwitch, speedEdit
    case speedReset, videoEqualizerReset, videoEqualizerSlider, audioDelayEdit, audioDelayReset, subDelayEdit, subDelayReset
    case audioDelayShown, subDelayShown, subPosShown, subScaleShown, subTextStyleShown, speedShown, osdChapterShown
    case menuSubFont, chooseSubFont, subFontButton
  }

  @Test("Each control of a player's window, sidebar or menu asks mpv in a request that returns before mpv handles it, and each view of a setting shows what mpv has without waiting for it",
        arguments: ControlRequest.allCases)
  func controlDoesNotWait(_ request: ControlRequest) async throws {
    try await Self.withPlayer { player, _ in
      player.syncUITimer?.invalidate()
      let mpv: MPVController = player.mpv
      let window: MainWindowController = player.mainWindow
      func item(_ representedObject: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = representedObject
        return item
      }
      func color(_ name: String) -> String? { mpv.getString("options/" + name) }
      let ask: () -> Void
      let applied: () -> Bool
      var cleanUp: () -> Void = {}
      var held = player
      switch request {
      case .menuAudioDevice:
        // The menu asks the active player, which is the player of the main window or else the first player, so its core is held.
        let active = PlayerCore.active
        held = active
        let device = active.getAudioDevices().last?.name ?? "auto"
        ask = { AppDelegate.shared.menuSelectAudioDevice(item(device)) }
        applied = { active.mpv.getString(MPVProperty.audioDevice) == device }
      case .playButton:
        // Playing while fast-forwarding returns the speed to normal.
        mpv.setDouble(MPVOption.PlaybackControl.speed, 2)
        try await Self.waitUntil { player.info.playSpeed == 2 }
        window.isFastforwarding = true
        ask = { window.playButtonAction(NSButton()) }
        applied = { mpv.getDouble(MPVOption.PlaybackControl.speed) == 1 }
      case .arrowButton:
        // The window is told that the arrow buttons change the speed, as it is when the setting changes, and the right button asks
        // for the speed after normal.
        window.observeValue(forKeyPath: Preference.Key.arrowButtonAction.rawValue, of: UserDefaults.standard,
                            change: [.newKey: Preference.ArrowButtonAction.speed.rawValue], context: nil)
        window.speedValueIndex = AppData.availableSpeedValues.count / 2 + 1
        let speed = AppData.availableSpeedValues[window.speedValueIndex]
        ask = { window.arrowButtonAction(left: false) }
        applied = { mpv.getDouble(MPVOption.PlaybackControl.speed) == speed }
      case .volumeSlider:
        // A step toward the middle of the range, so that the volume asked for is not clamped.
        let volume = player.info.volume + (player.info.volume >= 50 ? -10 : 10)
        let slider = NSSlider(value: volume, minValue: 0, maxValue: 100, target: nil, action: nil)
        ask = { window.volumeSliderChanges(slider) }
        applied = { mpv.getDouble(MPVOption.Audio.volume) == volume }
      case .muteButton:
        ask = { window.muteButtonAction(NSButton()) }
        applied = { mpv.getFlag(MPVOption.Audio.mute) }
      case .shuffleButton:
        let pane = Self.kept(SidebarPlaylistPane(player: player))
        ask = { pane.shuffleBtnAction(NSButton()) }
        applied = { player.info.isShuffled }
      case .subVisibilitySwitch, .secondSubVisibilitySwitch:
        let isPrimary = request == .subVisibilitySwitch
        let option = isPrimary ? MPVOption.Subtitles.subVisibility : MPVOption.Subtitles.secondarySubVisibility
        let visible = mpv.getFlag(option)
        try await Self.waitUntil { (isPrimary ? player.info.isSubVisible : player.info.isSecondSubVisible) == visible }
        // The switch of the primary subtitles comes first.
        let switches = Self.controls(NSSwitch.self, sending: "switchAction:", under: Self.kept(SidebarSubtitlesPane(player: player)))
        try #require(switches.count == 2)
        let visibilitySwitch = switches[isPrimary ? 0 : 1]
        ask = { Self.send(visibilitySwitch) }
        applied = { mpv.getFlag(option) != visible }
      case .subPosSlider:
        let pane = Self.kept(SidebarSubtitlesPane(player: player))
        let slider = try #require(Self.controls(NSSlider.self, sending: "positionAction:", under: pane).first)
        slider.intValue = 80
        ask = { Self.send(slider) }
        applied = { mpv.getInt(MPVOption.Subtitles.subPos) == 80 }
      case .subScaleReset:
        let pane = Self.kept(SidebarSubtitlesPane(player: player))
        let button = try #require(Self.controls(NSButton.self, sending: "scaleResetButtonAction:", under: pane).first)
        mpv.setDouble(MPVOption.Subtitles.subScale, 2)
        ask = { Self.send(button) }
        applied = { abs(mpv.getDouble(MPVOption.Subtitles.subScale) - 1) < 0.001 }
      case .subScaleSlider:
        let pane = Self.kept(SidebarSubtitlesPane(player: player))
        let slider = try #require(Self.controls(NSSlider.self, sending: "scaleAction:", under: pane).first)
        // The slider shows a scale of 2 at 1.
        slider.doubleValue = 1
        ask = { Self.send(slider) }
        applied = { abs(mpv.getDouble(MPVOption.Subtitles.subScale) - 2) < 0.001 }
      case .subFontSizePicker:
        let pane = Self.kept(SidebarSubtitlesPane(player: player))
        let picker = try #require(Self.controls(NSPopUpButton.self, sending: "chooseSubFontSizeAction:", under: pane).first)
        picker.selectItem(withTitle: "60")
        ask = { Self.send(picker) }
        applied = { mpv.getDouble("options/" + MPVOption.Subtitles.subFontSize) == 60 }
      case .subBorderSizePicker:
        let pane = Self.kept(SidebarSubtitlesPane(player: player))
        let picker = try #require(Self.controls(NSPopUpButton.self, sending: "chooseSubBorderSizeAction:", under: pane).first)
        picker.selectItem(withTitle: "4")
        ask = { Self.send(picker) }
        applied = { mpv.getDouble("options/" + MPVOption.Subtitles.subOutlineSize) == 4 }
      case .subTextColorWell, .subBackColorWell, .subBorderColorWell:
        // The wells of the text, background and border colors are tagged 1, 2 and 3.
        let tag = request == .subTextColorWell ? 1 : request == .subBackColorWell ? 2 : 3
        let option = [MPVOption.Subtitles.subColor, MPVOption.Subtitles.subBackColor, MPVOption.Subtitles.subOutlineColor][tag - 1]
        let pane = Self.kept(SidebarSubtitlesPane(player: player))
        let well = try #require(Self.controls(NSColorWell.self, sending: "colorAction:", under: pane).first(where: { $0.tag == tag }))
        let before = color(option)
        well.color = .red
        ask = { Self.send(well) }
        applied = { color(option) != before }
      case .aspectSegment:
        let pane = Self.kept(SidebarVideoPane(player: player))
        let segments = try #require(Self.controls(NSSegmentedControl.self, sending: "aspectRatioAction:", under: pane).first)
        segments.selectedSegment = try #require(AppData.aspectsInPanel.firstIndex(of: "16:9"))
        ask = { Self.send(segments) }
        applied = { abs(mpv.getDouble(MPVOption.Video.videoAspectOverride) - 16 / 9) < 0.01 }
      case .rotationSegment:
        let pane = Self.kept(SidebarVideoPane(player: player))
        let segments = try #require(Self.controls(NSSegmentedControl.self, sending: "rotationAction:", under: pane).first)
        segments.selectedSegment = try #require(AppData.rotations.firstIndex(of: 90))
        ask = { Self.send(segments) }
        applied = { mpv.getInt(MPVOption.Video.videoRotate) == 90 }
      case .hwdecSwitch:
        let pane = Self.kept(SidebarVideoPane(player: player))
        let hwdecSwitch = try #require(Self.controls(NSSwitch.self, sending: "hwdecAction:", under: pane).first)
        hwdecSwitch.state = .off
        ask = { Self.send(hwdecSwitch) }
        applied = { mpv.getString(MPVOption.Video.hwdec) == "no" }
      case .speedEdit:
        let view = try Self.sliderView(notifiedBy: .iinaSpeedChanged, under: Self.kept(SidebarVideoPane(player: player)))
        view.input.doubleValue = 2
        ask = { view.customEditFinishedAction() }
        applied = { mpv.getDouble(MPVOption.PlaybackControl.speed) == 2 }
      case .speedReset:
        let view = try Self.sliderView(notifiedBy: .iinaSpeedChanged, under: Self.kept(SidebarVideoPane(player: player)))
        mpv.setDouble(MPVOption.PlaybackControl.speed, 2)
        ask = { view.resetButtonAction() }
        applied = { mpv.getDouble(MPVOption.PlaybackControl.speed) == 1 }
      case .videoEqualizerReset:
        // The reset button and the slider of the brightness are tagged 1.
        let pane = Self.kept(SidebarVideoPane(player: player))
        let button = try #require(Self.controls(NSButton.self, sending: "resetAction:", under: pane).first(where: { $0.tag == 1 }))
        mpv.setInt(MPVOption.Equalizer.brightness, 10)
        ask = { Self.send(button) }
        applied = { mpv.getInt(MPVOption.Equalizer.brightness) == 0 }
      case .videoEqualizerSlider:
        let pane = Self.kept(SidebarVideoPane(player: player))
        let slider = try #require(Self.controls(NSSlider.self, sending: "sliderAction:", under: pane).first(where: { $0.tag == 1 }))
        slider.intValue = 10
        ask = { Self.send(slider) }
        applied = { mpv.getInt(MPVOption.Equalizer.brightness) == 10 }
      case .audioDelayEdit:
        let view = try Self.sliderView(notifiedBy: .iinaAudioDelayChanged, under: Self.kept(SidebarAudioPane(player: player)))
        view.input.doubleValue = 0.5
        ask = { view.customEditFinishedAction() }
        applied = { mpv.getDouble(MPVOption.Audio.audioDelay) == 0.5 }
      case .audioDelayReset:
        let view = try Self.sliderView(notifiedBy: .iinaAudioDelayChanged, under: Self.kept(SidebarAudioPane(player: player)))
        mpv.setDouble(MPVOption.Audio.audioDelay, 0.5)
        ask = { view.resetButtonAction() }
        applied = { mpv.getDouble(MPVOption.Audio.audioDelay) == 0 }
      case .subDelayEdit:
        let view = try Self.sliderView(notifiedBy: .iinaSubDelayChanged, under: Self.kept(SidebarSubtitlesPane(player: player)))
        view.input.doubleValue = 0.5
        ask = { view.customEditFinishedAction() }
        applied = { mpv.getDouble(MPVOption.Subtitles.subDelay) == 0.5 }
      case .subDelayReset:
        // The reset button of the subtitle delay resets the audio delay.
        let view = try Self.sliderView(notifiedBy: .iinaSubDelayChanged, under: Self.kept(SidebarSubtitlesPane(player: player)))
        mpv.setDouble(MPVOption.Audio.audioDelay, 0.5)
        ask = { view.resetButtonAction() }
        applied = { mpv.getDouble(MPVOption.Audio.audioDelay) == 0 }
      case .audioDelayShown:
        // The view shows mpv's delay once the player has stored it, then is cleared, so that what it shows next is what the request
        // shows.
        let view = try Self.sliderView(notifiedBy: .iinaAudioDelayChanged, under: Self.kept(SidebarAudioPane(player: player)))
        mpv.setDouble(MPVOption.Audio.audioDelay, 0.5)
        try await Self.waitUntil { player.info.audioDelay == 0.5 }
        view.input.doubleValue = 0
        ask = { view.update() }
        applied = { view.input.doubleValue == mpv.getDouble(MPVOption.Audio.audioDelay) }
      case .subDelayShown:
        let view = try Self.sliderView(notifiedBy: .iinaSubDelayChanged, under: Self.kept(SidebarSubtitlesPane(player: player)))
        mpv.setDouble(MPVOption.Subtitles.subDelay, 0.5)
        try await Self.waitUntil { player.info.subDelay == 0.5 }
        view.input.doubleValue = 0
        ask = { view.update() }
        applied = { view.input.doubleValue == mpv.getDouble(MPVOption.Subtitles.subDelay) }
      case .speedShown:
        let view = try Self.sliderView(notifiedBy: .iinaSpeedChanged, under: Self.kept(SidebarVideoPane(player: player)))
        mpv.setDouble(MPVOption.PlaybackControl.speed, 2)
        try await Self.waitUntil { player.info.playSpeed == 2 }
        view.input.doubleValue = 1
        ask = { view.update() }
        applied = { view.input.doubleValue == mpv.getDouble(MPVOption.PlaybackControl.speed) }
      case .subPosShown:
        let pane = Self.kept(SidebarSubtitlesPane(player: player))
        let slider = try #require(Self.controls(NSSlider.self, sending: "positionAction:", under: pane).first)
        mpv.setInt(MPVOption.Subtitles.subPos, 80)
        try await Self.waitUntil { player.info.subPos == 80 }
        slider.intValue = 0
        ask = { player.postNotification(.iinaSubPositionChanged) }
        applied = { Int(slider.intValue) == mpv.getInt(MPVOption.Subtitles.subPos) }
      case .subScaleShown:
        // mpv does not report the font, which the view shows once mpv answers.
        let pane = Self.kept(SidebarSubtitlesPane(player: player))
        let slider = try #require(Self.controls(NSSlider.self, sending: "scaleAction:", under: pane).first)
        let fontButton = try #require(Self.controls(NSButton.self, sending: "chooseSubFontAction:", under: pane).first)
        _ = mpv.setString(MPVOption.Subtitles.subFont, "Helvetica")
        mpv.setDouble(MPVOption.Subtitles.subScale, 2)
        try await Self.waitUntil { player.info.subScale == 2 && fontButton.title == "Helvetica" }
        slider.doubleValue = 0
        fontButton.title = ""
        ask = { player.postNotification(.iinaSubScaleChanged) }
        // The slider shows a scale of 1 or more at 1 less.
        applied = {
          slider.doubleValue == mpv.getDouble(MPVOption.Subtitles.subScale) - 1
            && fontButton.title == mpv.getString(MPVOption.Subtitles.subFont)
        }
      case .subTextStyleShown:
        // The text style is shown when the view is made, so the view is made while the core is held.
        mpv.setDouble(MPVOption.Subtitles.subFontSize, 60)
        mpv.setDouble(MPVOption.Subtitles.subOutlineSize, 2.5)
        var pane: NSView?
        ask = { pane = Self.kept(SidebarSubtitlesPane(player: player)) }
        applied = {
          guard let pane,
                let size = Self.controls(NSPopUpButton.self, sending: "chooseSubFontSizeAction:", under: pane).first,
                let border = Self.controls(NSPopUpButton.self, sending: "chooseSubBorderSizeAction:", under: pane).first else {
            return false
          }
          return size.titleOfSelectedItem == Int(mpv.getDouble(MPVOption.Subtitles.subFontSize)).description
            && border.titleOfSelectedItem.flatMap { Double($0) } == mpv.getDouble(MPVOption.Subtitles.subOutlineSize)
        }
      case .osdChapterShown:
        // The file has no chapters, so mpv has none as current, which the OSD of a chapter shows first, by the number of none.
        let osd = Self.kept(OSDView(mainWindow: window))
        ask = { osd.updateViews(fromMessage: .chapter("iinaTests"), player: player) }
        applied = {
          osd.secondaryLabel.stringValue.hasPrefix("(\(mpv.getInt(MPVProperty.chapter) + 1)/\(player.info.chapters.count))")
        }
      case .menuSubFont, .chooseSubFont, .subFontButton:
        let picker = AppDelegate.shared.fontPicker
        picker.finishedPicking = nil
        switch request {
        case .menuSubFont:
          let handler = MainMenuActionHandler(playerCore: player)
          ask = { handler.menuSubFont(item()) }
        case .subFontButton:
          let pane = Self.kept(SidebarSubtitlesPane(player: player))
          let button = try #require(Self.controls(NSButton.self, sending: "chooseSubFontAction:", under: pane).first)
          ask = { Self.send(button) }
        default:
          ask = { player.chooseSubFont() }
        }
        // The picker is shown once mpv answers with the font, then closed unpicked.
        applied = { picker.finishedPicking != nil && picker.window?.isVisible == true }
        cleanUp = {
          picker.finishedPicking = nil
          picker.close()
        }
      }
      defer { cleanUp() }
      let returnedWhileHeld = try await Self.returnsWhileHeld(held, ask)
      #expect(returnedWhileHeld, "Asking for \(request) waited for mpv")
      try await Self.waitUntil(applied)
    }
  }

  /// A request the app, the settings, the system or a plugin makes of a player: each is a site that must not wait for `mpv` on the
  /// main thread.
  enum AppRequest: String, CaseIterable, Sendable {
    case fullScreenState, preferenceOptions, spdif, urlScheme, externalAudio, mouseResetSpeed, menuTogglePause, remotePlaybackRate
    case jsSpeed, jsChapter, jsAudioDelay, jsSubDelay, jsVolume, jsMute, jsLoadTrack
  }

  @Test("Each request the app, the settings, the system or a plugin makes of a player asks mpv in a request that returns before mpv handles it",
        arguments: AppRequest.allCases)
  func appRequestDoesNotWait(_ request: AppRequest) async throws {
    try await Self.withPlayer { player, folder in
      player.syncUITimer?.invalidate()
      let mpv: MPVController = player.mpv
      let window: MainWindowController = player.mainWindow
      // A plugin's script is read when its instance is made, so the instance is made before the core is held. The plugin is kept,
      // since its instance holds it weakly and reads it when the instance is let go.
      let plugin = try Self.makePlugin(in: folder, permissions: ["file-system"])
      Self.keptPlugins.append(plugin)
      let instance = JavascriptPluginInstance(player: player, plugin: plugin)
      func script(_ source: String) -> () -> Void {
        { _ = instance.js.evaluateScript(source) }
      }
      let ask: () -> Void
      let applied: () -> Bool
      var cleanUp: () -> Void = {}
      var held = player
      var opened: [PlayerCore] = []
      switch request {
      case .fullScreenState:
        // The state is set as the window sets it once it is in full screen, so the flag mpv then reports is the state of the window.
        let frame = try #require(window.window).frame
        ask = { window.fsState = .fullscreen(legacy: false, priorWindowedFrame: frame) }
        applied = { mpv.getFlag(MPVOption.Window.fullscreen) }
      case .preferenceOptions:
        // The settings are changed in the argument domain, and mpv is told of each as it is told when a setting changes.
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let settings: [Preference.Key: Any] = [.subMarginY: 40, .subBlur: 0.5, .subItalic: true, .subLang: "fr",
                                               .subTextColorString: "1.0/0.0/0.0/1.0",
                                               .subAlignX: Preference.SubAlignX.left.rawValue]
        defaults.setVolatileDomain(arguments.merging(settings.map { ($0.key.rawValue, $0.value) }) { $1 },
                                   forName: UserDefaults.argumentDomain)
        cleanUp = { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        let color = mpv.getString(MPVOption.Subtitles.subColor)
        ask = {
          for key in settings.keys {
            mpv.observeValue(forKeyPath: key.rawValue, of: defaults, change: [.oldKey: 0, .newKey: 1], context: nil)
          }
        }
        applied = {
          mpv.getInt(MPVOption.Subtitles.subMarginY) == 40 && abs(mpv.getDouble(MPVOption.Subtitles.subBlur) - 0.5) < 0.001
            && mpv.getFlag(MPVOption.Subtitles.subItalic) && mpv.getString(MPVOption.TrackSelection.slang) == "fr"
            && mpv.getString(MPVOption.Subtitles.subColor) != color && mpv.getString(MPVOption.Subtitles.subAlignX) == "left"
        }
      case .spdif:
        // The settings ask every player, among which the player is put for the request.
        let codec = PrefCodecViewController()
        _ = codec.view
        let buttons: [NSButton] = [codec.spdifAC3Btn, codec.spdifDTSBtn, codec.spdifDTSHDBtn]
        buttons.forEach { $0.state = .off }
        codec.spdifAC3Btn.state = .on
        PlayerCore.playerCores.append(player)
        cleanUp = {
          PlayerCore.playerCores.removeAll { $0 === player }
          buttons.forEach { $0.state = .off }
          codec.spdifBtnAction(codec.spdifAC3Btn)
        }
        ask = { codec.spdifBtnAction(codec.spdifAC3Btn) }
        applied = { mpv.getString(MPVOption.Audio.audioSpdif) == "ac3" }
      case .urlScheme:
        // The link opens its file in a new window, whose player is the idle player whose core is held, and sets an mpv option on it.
        let target = PlayerCore.newPlayerCore
        held = target
        opened = [target]
        let file = folder.appendingPathComponent("a.mp4")
        var link = URLComponents()
        link.scheme = "iina"
        link.host = "open"
        link.queryItems = [URLQueryItem(name: "url", value: file.path), URLQueryItem(name: "new_window", value: "1"),
                           URLQueryItem(name: "mpv_slang", value: "fr")]
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: try #require(link.string)), forKeyword: keyDirectObject)
        ask = { AppDelegate.shared.handleURLEvent(event: event, withReplyEvent: NSAppleEventDescriptor.null()) }
        applied = {
          target.info.currentURL?.path == file.path && target.info.state == .paused && !target.info.pausedForLoading
            && target.mpv.getString(MPVOption.TrackSelection.slang) == "fr"
        }
      case .externalAudio, .jsLoadTrack:
        let audio = try Self.writeSilence("d", in: folder)
        let tracks = player.info.audioTracks.count
        ask = request == .externalAudio ? { player.loadExternalAudioFile(audio) }
          : script("iina.core.audio.loadTrack(\"\(audio.path)\")")
        applied = { player.info.audioTracks.count > tracks }
      case .mouseResetSpeed, .menuTogglePause:
        // Resetting the speed, and pausing or resuming while fast-forwarding, return the speed to normal.
        mpv.setDouble(MPVOption.PlaybackControl.speed, 2)
        try await Self.waitUntil { player.info.playSpeed == 2 }
        if request == .mouseResetSpeed {
          ask = { window.performMouseAction(.resetSpeed) }
        } else {
          window.isFastforwarding = true
          let handler = MainMenuActionHandler(playerCore: player)
          ask = { handler.menuTogglePause(NSMenuItem()) }
        }
        applied = { mpv.getDouble(MPVOption.PlaybackControl.speed) == 1 }
      case .remotePlaybackRate:
        // The command asks the last active player.
        let lastActive = PlayerCore.lastActive
        PlayerCore.lastActive = player
        cleanUp = { PlayerCore.lastActive = lastActive }
        ask = { RemoteCommandController.changePlaybackRate(1.5) }
        applied = { mpv.getDouble(MPVOption.PlaybackControl.speed) == 1.5 }
      case .jsSpeed:
        ask = script("iina.core.setSpeed(2)")
        applied = { mpv.getDouble(MPVOption.PlaybackControl.speed) == 2 }
      case .jsChapter:
        // The test files have no chapters, so the player is given one starting 2 s in, which playing the chapter seeks to.
        player.info.chapters = [MPVChapter(title: "iinaTests", startTime: 2, index: 0)]
        ask = script("iina.core.playChapterWithIndex(0)")
        applied = { mpv.getDouble(MPVProperty.timePos) >= 1.9 }
      case .jsAudioDelay:
        ask = script("iina.core.audio.delay = 0.5")
        applied = { mpv.getDouble(MPVOption.Audio.audioDelay) == 0.5 }
      case .jsSubDelay:
        ask = script("iina.core.subtitle.delay = 0.5")
        applied = { mpv.getDouble(MPVOption.Subtitles.subDelay) == 0.5 }
      case .jsVolume:
        // A step toward the middle of the range, so that the volume asked for is not clamped.
        let volume = player.info.volume + (player.info.volume >= 50 ? -10 : 10)
        ask = script("iina.core.audio.volume = \(volume)")
        applied = { mpv.getDouble(MPVOption.Audio.volume) == volume }
      case .jsMute:
        ask = script("iina.core.audio.muted = true")
        applied = { mpv.getFlag(MPVOption.Audio.mute) }
      }
      defer { cleanUp() }
      let returnedWhileHeld = try await Self.returnsWhileHeld(held, ask)
      #expect(returnedWhileHeld, "Asking for \(request) waited for mpv")
      try await Self.waitUntil(applied)
      try await Self.close(opened)
    }
  }

  /// A site that asks LaunchServices to open a link or a file, to show files in Finder or to make IINA the default app: each must
  /// not wait for LaunchServices on the main thread.
  enum LaunchServicesRequest: String, CaseIterable, Sendable {
    case historyShowInFinder, aboutCommit, aboutContributors, aboutTranslators, menuScreenshotFolder, menuHelp, menuGithub
    case menuWebsite, assrtRegister, jsShowInFinder, guideWebsite, guideLink, jsOpenLink, jsOpenFile, menuShowInFinder
    case prefLogFolder, prefAdvancedHelp, prefToneMappingHelp, prefTargetPeakHelp, prefAlgorithmHelp, prefGainAdjustmentHelp
    case prefGaplessAudioHelp, prefAudioDriverHelp, prefShowConfFile, prefKeyBindingsHelp, prefYtdlHelp, prefPluginWebsite
    case prefPluginEmail, prefShowPlugin, prefOpenSubHelp, prefAssrtHelp, prefSubOverrideHelp, prefDisableAnimationsHelp
    case prefSetAsDefault, prefExtChrome, prefExtFirefox, screenshotReveal, screenshotEdit, settingsHelpLink, settingsLogFolder
    case settingsShowConfFile, settingsShowPlugin, settingsPluginLink, settingsAssrtHelp, settingsSetAsDefault
    case settingsExtChrome, settingsExtFirefox, playlistShowInFinder, playlistOpenInBrowser, titlebarShowFolder

    /// Whether the site is reached through a player.
    var needsPlayer: Bool {
      [.jsShowInFinder, .jsOpenLink, .jsOpenFile, .menuShowInFinder, .playlistShowInFinder, .playlistOpenInBrowser,
       .titlebarShowFolder].contains(self)
    }
  }

  @Test("Each request of LaunchServices the app, its windows, the settings or a plugin makes returns before LaunchServices is asked, which is then asked for what the site was asked for",
        arguments: LaunchServicesRequest.allCases)
  func workspaceRequestDoesNotWait(_ request: LaunchServicesRequest) async throws {
    if request.needsPlayer {
      try await Self.withPlayer { player, folder in
        try await Self.checkWorkspaceRequest(request, player: player, folder: folder)
      }
    } else {
      let folder = try Self.makeFolder()
      defer { try? FileManager.default.removeItem(at: folder) }
      try await Self.checkWorkspaceRequest(request, player: nil, folder: folder)
    }
  }

  /// Objects made in a test that observe settings, notices or their parent without keeping themselves, kept for as long as they may
  /// be notified.
  private static var keptObjects: [AnyObject] = []

  /// Make `request` while `Utility.workspaceQueue` is held, expecting it to return before LaunchServices is asked, then let the queue
  /// go and expect LaunchServices to be asked for what the site was asked for.
  /// - Parameter player: The player playing `b.mp4` of `folder`, for a request that `needsPlayer`.
  private static func checkWorkspaceRequest(_ request: LaunchServicesRequest, player: PlayerCore?, folder: URL) async throws {
    let file = folder.appendingPathComponent("a.mp4")
    let link = try #require(URL(string: "https://iina.io/"))
    func url(_ string: String) throws -> URL {
      try #require(URL(string: string))
    }
    func makeTestPlugin() throws -> JavascriptPlugin {
      // Kept, since the instances, views and windows showing a plugin hold it without keeping it.
      let plugin = try makePlugin(in: folder, permissions: ["file-system"],
                                  author: ["name": "iinaTests", "url": link.absoluteString, "email": "tests@iina.io"])
      keptPlugins.append(plugin)
      return plugin
    }
    func script(_ source: String) throws -> () -> Void {
      // A plugin's script is read when its instance is made, so the instance is made before the queue is held.
      let player = try #require(player)
      let instance = JavascriptPluginInstance(player: player, plugin: try makeTestPlugin())
      return { _ = instance.js.evaluateScript(source) }
    }
    // With every kind of media checked IINA is made the default app of each content type once, MP4 videos and MP3 audio among them.
    let bundleID = try #require(Bundle.main.bundleIdentifier)
    func setsDefaultApp(_ requests: [Utility.WorkspaceRequest]) -> Bool {
      let types = requests.compactMap { request -> String? in
        guard case let .setDefaultApp(type, id) = request, id == bundleID else { return nil }
        return type
      }
      return types.count == requests.count && Set(types).count == types.count
        && Set(types).isSuperset(of: ["public.mpeg-4", "public.mp3"])
    }
    let ask: () -> Void
    var expected: [Utility.WorkspaceRequest] = []
    var asked: (([Utility.WorkspaceRequest]) -> Bool)?
    var cleanUp: () -> Void = {}
    switch request {
    case .historyShowInFinder:
      // The files shown are those of the selected entries that exist, so an entry whose file is missing is also selected.
      let entries = [file, folder.appendingPathComponent("missing.mp4")].map {
        PlaybackHistory(url: $0, duration: 4, title: nil, mpvMd5: $0.path)
      }
      let controller = AppDelegate.shared.historyWindow
      let history = HistoryController.shared.history
      HistoryController.shared.history = entries
      cleanUp = {
        HistoryController.shared.history = history
        controller.reloadData()
      }
      controller.reloadData()
      let outlineView = controller.outlineView
      outlineView.selectRowIndexes(IndexSet(integersIn: 0..<outlineView.numberOfRows), byExtendingSelection: false)
      ask = { controller.showInFinderAction(nil) }
      expected = [.revealInFinder([file])]
    case .aboutCommit:
      let commit = try #require(InfoDictionary.shared.buildCommit)
      let controller = AppDelegate.shared.aboutWindow
      ask = { controller.openCommitLink() }
      expected = [.open(try url("https://github.com/iina/iina/commit/\(commit)"))]
    case .aboutContributors:
      let controller = AppDelegate.shared.aboutWindow
      ask = { controller.contributorsBtnAction(controller) }
      expected = [.open(try url(AppData.contributorsLink))]
    case .aboutTranslators:
      let controller = AppDelegate.shared.aboutWindow
      ask = { controller.translatorsBtnAction(controller) }
      expected = [.open(try url(AppData.crowdinMembersLink))]
    case .menuScreenshotFolder:
      let path = NSString(string: try #require(Preference.string(for: .screenshotFolder))).expandingTildeInPath
      ask = { AppDelegate.shared.menuOpenScreenshotFolder(NSMenuItem()) }
      expected = [.open(URL(fileURLWithPath: path, isDirectory: true))]
    case .menuHelp:
      ask = { AppDelegate.shared.helpAction(NSMenuItem()) }
      expected = [.open(try url(AppData.wikiLink))]
    case .menuGithub:
      ask = { AppDelegate.shared.githubAction(NSMenuItem()) }
      expected = [.open(try url(AppData.githubLink))]
    case .menuWebsite:
      ask = { AppDelegate.shared.websiteAction(NSMenuItem()) }
      expected = [.open(try url(AppData.websiteLink))]
    case .assrtRegister:
      // A user without a token of their own who chooses to register is shown the register page, then asked for their token, which
      // the prompt being dismissed leaves unset.
      let fetcher = Assrt.Fetcher()
      fetcher.usesUserToken = false
      let prompts = ModalWindowDismisser(answering: [.alertFirstButtonReturn])
      cleanUp = { prompts.stop() }
      ask = { _ = fetcher.checkToken() }
      expected = [.open(try url(AppData.assrtRegisterLink))]
    case .jsShowInFinder:
      ask = try script("iina.file.showInFinder(\"\(file.path)\")")
      expected = [.revealInFinder([URL(fileURLWithPath: file.path)])]
    case .jsOpenLink:
      ask = try script("iina.utils.open(\"\(link.absoluteString)\")")
      expected = [.open(link)]
    case .jsOpenFile:
      ask = try script("iina.utils.open(\"\(file.path)\")")
      expected = [.open(URL(fileURLWithPath: file.path))]
    case .guideWebsite:
      let controller = AppDelegate.shared.guideWindow
      ask = { controller.visitIINAWebsite(controller) }
      expected = [.open(try url(AppData.websiteLink))]
    case .guideLink:
      // A link to a page other than the highlights is opened in the browser.
      let controller = AppDelegate.shared.guideWindow
      let webView = WKWebView()
      let action = NavigationAction(link)
      ask = { controller.webView(webView, decidePolicyFor: action, decisionHandler: { _ in }) }
      expected = [.open(link)]
    case .menuShowInFinder:
      let player = try #require(player)
      let handler = MainMenuActionHandler(playerCore: player)
      ask = { handler.menuShowCurrentFileInFinder(NSMenuItem()) }
      expected = [.revealInFinder([try #require(player.info.currentURL)])]
    case .prefLogFolder:
      let controller = PrefAdvancedViewController()
      ask = { controller.openLogDir(controller) }
      expected = [.open(Logger.logDirectory)]
    case .prefAdvancedHelp:
      let controller = PrefAdvancedViewController()
      ask = { controller.helpBtnAction(controller) }
      expected = [.open(try url(AppData.wikiLink).appendingPathComponent("MPV-Options-and-Properties"))]
    case .prefToneMappingHelp, .prefTargetPeakHelp, .prefAlgorithmHelp, .prefGainAdjustmentHelp, .prefGaplessAudioHelp,
         .prefAudioDriverHelp:
      let controller = PrefCodecViewController()
      let help: String
      switch request {
      case .prefToneMappingHelp:
        ask = { controller.toneMappingHelpAction(controller) }
        help = AppData.toneMappingHelpLink
      case .prefTargetPeakHelp:
        ask = { controller.targetPeakHelpAction(controller) }
        help = AppData.mpvManualLink.appending("/#options-target-peak")
      case .prefAlgorithmHelp:
        ask = { controller.algorithmHelpAction(controller) }
        help = AppData.mpvManualLink.appending("/#options-tone-mapping")
      case .prefGainAdjustmentHelp:
        ask = { controller.gainAdjustmentHelpAction(controller) }
        help = AppData.mpvManualLink.appending("/#options-replaygain")
      case .prefGaplessAudioHelp:
        ask = { controller.gaplessAudioHelpAction(controller) }
        help = AppData.mpvManualLink.appending("/#options-gapless-audio")
      default:
        ask = { controller.audioDriverHelpAction(controller) }
        help = AppData.mpvManualLink.appending("/#audio-output-drivers-coreaudio")
      }
      expected = [.open(try url(help))]
    case .prefShowConfFile:
      let conf = folder.appendingPathComponent("iinaTests.conf")
      try Data().write(to: conf)
      let controller = PrefKeyBindingViewController()
      controller.currentConfFilePath = conf.path
      ask = { controller.showConfFileAction(controller) }
      expected = [.revealInFinder([URL(fileURLWithPath: conf.path)])]
    case .prefKeyBindingsHelp:
      let controller = PrefKeyBindingViewController()
      ask = { controller.openKeyBindingsHelpAction(controller) }
      expected = [.open(try url(AppData.wikiLink.appending("/Manage-Key-Bindings")))]
    case .prefYtdlHelp:
      let controller = PrefNetworkViewController()
      ask = { controller.ytdlHelpAction(controller) }
      expected = [.open(try url(AppData.ytdlHelpLink))]
    case .prefPluginWebsite, .prefPluginEmail, .prefShowPlugin:
      let plugin = try makeTestPlugin()
      let controller = PrefPluginViewController()
      controller.currentPlugin = plugin
      switch request {
      case .prefPluginWebsite:
        ask = { controller.websiteBtnAction(NSButton()) }
        expected = [.open(link)]
      case .prefPluginEmail:
        ask = { controller.emailBtnAction(NSButton()) }
        expected = [.open(try url("mailto:tests@iina.io"))]
      default:
        ask = { controller.showPlugin(controller) }
        expected = [.revealInFinder([plugin.root])]
      }
    case .prefOpenSubHelp, .prefAssrtHelp, .prefSubOverrideHelp:
      let controller = PrefSubViewController()
      switch request {
      case .prefOpenSubHelp:
        ask = { controller.openSubHelpBtnAction(controller) }
        expected = [.open(try url(AppData.wikiLink.appending("/Download-Online-Subtitles#opensubtitles")))]
      case .prefAssrtHelp:
        ask = { controller.assrtHelpBtnAction(controller) }
        expected = [.open(try url(AppData.wikiLink.appending("/Download-Online-Subtitles#assrt")))]
      default:
        ask = { controller.subOverrideHelpBtnAction(controller) }
        expected = [.open(try url("https://mpv.io/manual/stable/#options-sub-ass-override"))]
      }
    case .prefDisableAnimationsHelp:
      let controller = PrefUIViewController()
      ask = { controller.disableAnimationsHelpAction(controller) }
      expected = [.open(try url(AppData.disableAnimationsHelpLink))]
    case .prefSetAsDefault:
      // The settings set IINA as the default app from a sheet on their window.
      let controller = PrefUtilsViewController()
      let window = NSWindow(contentViewController: controller)
      [controller.setAsDefaultVideoCheckBox, controller.setAsDefaultAudioCheckBox,
       controller.setAsDefaultPlaylistCheckBox].forEach { $0?.state = .on }
      window.beginSheet(try #require(controller.setAsDefaultSheet), completionHandler: nil)
      // The alert the settings show once they are done is a sheet on their window too.
      cleanUp = { window.sheets.forEach { window.endSheet($0) } }
      ask = { controller.setAsDefaultOKBtnAction(controller) }
      asked = setsDefaultApp
    case .prefExtChrome, .prefExtFirefox:
      let controller = PrefUtilsViewController()
      if request == .prefExtChrome {
        ask = { controller.extChromeBtnAction(controller) }
        expected = [.open(try url(AppData.chromeExtensionLink))]
      } else {
        ask = { controller.extFirefoxBtnAction(controller) }
        expected = [.open(try url(AppData.firefoxExtensionLink))]
      }
    case .screenshotReveal, .screenshotEdit:
      let osd = ScreenshootOSDView()
      osd.setImage(NSImage(), size: .zero, fileURL: file)
      if request == .screenshotReveal {
        ask = { osd.revealBtnAction(osd) }
        expected = [.revealInFinder([file])]
      } else {
        ask = { osd.editBtnAction(osd) }
        expected = [.open(file)]
      }
    case .settingsHelpLink:
      let item = SettingsItem.General().withHelpLink(AppData.wikiLink)
      ask = { _ = NSApp.sendAction(NSSelectorFromString("openHelpLink:"), to: item, from: nil) }
      expected = [.open(try url(AppData.wikiLink))]
    case .settingsLogFolder:
      let page = SettingsPageAdvanced()
      keptObjects.append(page)
      ask = { _ = NSApp.sendAction(NSSelectorFromString("openLogFolder"), to: page, from: nil) }
      expected = [.open(Logger.logDirectory)]
    case .settingsShowConfFile:
      let editor = ConfigEditor()
      keptObjects.append(editor)
      let path = try #require(editor.currentConfFilePath)
      ask = { editor.showConfFileAction(editor) }
      expected = [.revealInFinder([URL(fileURLWithPath: path)])]
    case .settingsShowPlugin:
      let plugin = try makeTestPlugin()
      let page = SettingsPagePlugin()
      let list = PluginListView(page: page)
      keptObjects += [page, list]
      let current = PluginListView.currentPlugin
      PluginListView.currentPlugin = plugin
      cleanUp = { PluginListView.currentPlugin = current }
      ask = { list.showPluginInFinderAction(list) }
      expected = [.revealInFinder([plugin.root])]
    case .settingsPluginLink:
      // A page of a plugin's about tab that links to an external page has it opened in the browser.
      let parent = NSWindow()
      let details = PluginDetailsWindow(plugin: try makeTestPlugin(), window: parent)
      keptObjects += [parent, details]
      let webView = WKWebView()
      let action = NavigationAction(link)
      ask = { details.webView(webView, decidePolicyFor: action, decisionHandler: { _ in }) }
      expected = [.open(link)]
    case .settingsAssrtHelp:
      let view = SubtitleSourceView()
      keptObjects.append(view)
      ask = { _ = NSApp.sendAction(NSSelectorFromString("assrtHelpBtnAction:"), to: view, from: nil) }
      expected = [.open(try url(AppData.wikiLink.appending("/Download-Online-Subtitles#assrt")))]
    case .settingsSetAsDefault:
      // The settings set IINA as the default app from a sheet on their window, with every kind of media checked at first.
      let window = NSWindow()
      let sheet = SetAsDefaultSheetWindow()
      sheet.contextWindow = window
      window.beginSheet(sheet, completionHandler: nil)
      // The alert the settings show once they are done is a sheet on their window too.
      cleanUp = { window.sheets.forEach { window.endSheet($0) } }
      ask = { sheet.okBtnAction(sheet) }
      asked = setsDefaultApp
    case .settingsExtChrome, .settingsExtFirefox:
      let view = BrowserExtensionView()
      if request == .settingsExtChrome {
        ask = { view.extChromeBtnAction(view) }
        expected = [.openInApp(try url(AppData.chromeExtensionLink), bundleID: "com.google.Chrome")]
      } else {
        ask = { view.extFirefoxBtnAction(view) }
        expected = [.openInApp(try url(AppData.firefoxExtensionLink), bundleID: "org.mozilla.firefox")]
      }
    case .playlistShowInFinder, .playlistOpenInBrowser:
      let player = try #require(player)
      try await waitUntil { player.info.playlist.count == 3 }
      let pane = kept(SidebarPlaylistPane(player: player))
      if request == .playlistShowInFinder {
        pane.selectedRows = IndexSet([0, 2])
        ask = { pane.contextMenuShowInFinder(NSMenuItem()) }
        expected = [.revealInFinder([0, 2].map { URL(fileURLWithPath: player.info.playlist[$0].filename) })]
      } else {
        // Only an entry read over the network is opened in the browser, so a link is added to the playlist after its files.
        player.addToPlaylist(paths: [link.absoluteString])
        try await waitUntil { player.info.playlist.count == 4 }
        try #require(player.info.playlist[3].isNetworkResource)
        pane.selectedRows = IndexSet([3])
        ask = { pane.contextOpenInBrowser(NSMenuItem()) }
        expected = [.open(link)]
      }
    case .titlebarShowFolder:
      // Each item of the menu of the path of the file shown in the title shows the folder it names in Finder.
      let player = try #require(player)
      let titlebar = kept(Titlebar(mainWindow: player.mainWindow))
      let item = NSMenuItem()
      item.representedObject = folder
      ask = { _ = NSApp.sendAction(NSSelectorFromString("revealInFinder:"), to: titlebar, from: item) }
      expected = [.showFolderInFinder(folder.path)]
    }
    defer { cleanUp() }
    let (returnedWhileHeld, made) = await workspaceRequestsWhileHeld(ask)
    #expect(returnedWhileHeld, "Asking for \(request) waited for LaunchServices")
    if let asked {
      #expect(asked(made), "Asking for \(request) asked LaunchServices for \(made)")
    } else {
      #expect(made == expected)
    }
    // What the site does on the main thread once LaunchServices has answered is done before the test cleans up after it.
    await drainMain()
  }

  /// Make `request` while `Utility.workspaceQueue` is held, the LaunchServices requests being recorded in place of being made, then
  /// let the queue go and wait until it has done what it was asked.
  /// - Returns: Whether `request` returned while the queue was held, before any LaunchServices request had been made, and the
  ///     LaunchServices requests made.
  private static func workspaceRequestsWhileHeld(_ request: () -> Void) async -> (Bool, [Utility.WorkspaceRequest]) {
    let recorder = WorkspaceRecorder()
    let make = Utility.makeWorkspaceRequest
    Utility.makeWorkspaceRequest = recorder.record
    defer { Utility.makeWorkspaceRequest = make }
    let hold = QueueHold(Utility.workspaceQueue, limit: holdLimit)
    request()
    let returnedWhileHeld = !hold.limitPassed && recorder.requests.isEmpty
    hold.release()
    // The queue runs what it was asked in order, so it has done what the request asked once it reaches this.
    await withCheckedContinuation { continuation in Utility.workspaceQueue.async { continuation.resume() } }
    return (returnedWhileHeld, recorder.requests)
  }

  /// A site that reads the audio devices or the audio device, or checks whether a config file exists.
  enum DeviceOrFileRequest: String, CaseIterable, Sendable {
    case audioDevices, audioDeviceListChanged, currentAoChanged, configuredAudioDevice, audioDeviceMenu, prefAudioDevices
    case settingsAudioDevices, prefNewConfigFile, settingsNewConfigFile
  }

  @Test("Each read of the audio devices, the audio device or a new config file's name returns before mpv or the file system is asked, then does what the site was asked",
        arguments: DeviceOrFileRequest.allCases)
  func deviceOrFileRequestDoesNotWait(_ request: DeviceOrFileRequest) async throws {
    switch request {
    case .prefNewConfigFile, .settingsNewConfigFile:
      try await Self.checkNewConfigFile(request)
    default:
      try await Self.withPlayer { player, _ in
        try await Self.checkAudioDeviceRequest(request, player: player)
      }
    }
  }

  /// Make `request` while the core of the `mpv` it reads is held, expecting it to return before `mpv` answers, then let the core go
  /// and expect the site to have done what it was asked.
  /// - Parameter player: The player playing `b.mp4`.
  private static func checkAudioDeviceRequest(_ request: DeviceOrFileRequest, player: PlayerCore) async throws {
    let mpv: MPVController = player.mpv
    // A device that no audio output driver has. mpv takes it as the audio device to use without opening it while nothing plays.
    let missing = "coreaudio/iinaTests"
    // The menu and the settings ask the active player, which is the player of the main window or else the first player.
    let active = PlayerCore.active
    // The sites read the devices and the device mpv reported in place of asking mpv.
    try await waitUntil { !player.info.audioDeviceList.isEmpty && player.info.audioDevice != nil }
    try await waitUntil { !active.info.audioDeviceList.isEmpty && active.info.audioDevice != nil }
    func popUps(in view: NSView) -> [NSPopUpButton] {
      var found = view.subviews.flatMap { popUps(in: $0) }
      if let popUp = view as? NSPopUpButton {
        found.insert(popUp, at: 0)
      }
      return found
    }
    func names(_ popUp: NSPopUpButton?) -> [String]? {
      popUp?.itemArray.compactMap { ($0.representedObject as? MPVAudioDevice)?.name }
    }
    let ask: () -> Void
    let applied: () -> Bool
    var cleanUp: () -> Void = {}
    var held = player
    switch request {
    case .audioDevices:
      var devices: [MPVAudioDevice] = []
      ask = { devices = player.getAudioDevices() }
      // mpv always lists the device that follows the system's choice.
      applied = { devices.contains { $0.name == "auto" } }
    case .audioDeviceListChanged:
      mpv.setString(MPVProperty.audioDevice, missing)
      try await waitUntil { player.info.audioDevice == missing }
      let list = player.info.audioDeviceList
      ask = { player.audioDeviceListChanged(list) }
      applied = { mpv.getString(MPVProperty.audioDevice) == "auto" }
    case .currentAoChanged:
      // A device mpv lists for the open driver, asked for as the same device of the driver that is not open.
      let device = try #require(player.getAudioDevices().first(where: { $0.driver == "coreaudio" }),
                                "mpv lists no Core Audio device")
      let other = MPVAudioDevice(device, "avfoundation").name
      mpv.setString(MPVProperty.audioDevice, other)
      try await waitUntil { player.info.audioDevice == other }
      ask = { player.currentAoChanged("coreaudio") }
      applied = { mpv.getString(MPVProperty.audioDevice) == device.name }
    case .configuredAudioDevice:
      let defaults = UserDefaults.standard
      let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
      defaults.setVolatileDomain(arguments.merging([Preference.Key.audioDevice.rawValue: missing]) { $1 },
                                 forName: UserDefaults.argumentDomain)
      cleanUp = { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
      mpv.setString(MPVProperty.audioDevice, missing)
      try await waitUntil { player.info.audioDevice == missing }
      ask = { player.checkConfiguredAudioDevice() }
      applied = { mpv.getString(MPVProperty.audioDevice) == "auto" }
    case .audioDeviceMenu:
      held = active
      let menuController = try #require(AppDelegate.shared.menuController)
      let menu: NSMenu = menuController.audioDeviceMenu
      ask = { menuController.menuWillOpen(menu) }
      applied = {
        let devices = active.getAudioDevices()
        return menu.items.compactMap { $0.representedObject as? String } == devices.map(\.name)
          && menu.items.filter { $0.state == .on }.compactMap { $0.representedObject as? String }
            == devices.filter { $0.name == active.info.audioDevice }.map(\.name)
      }
    case .prefAudioDevices:
      held = active
      let codec = PrefCodecViewController()
      _ = codec.view
      // The settings list the devices again when the audio driver setting changes.
      ask = {
        codec.observeValue(forKeyPath: Preference.Key.audioDriverEnableAVFoundation.rawValue, of: UserDefaults.standard,
                           change: [:], context: nil)
      }
      applied = { names(codec.audioDevicePopUp) == active.getAudioDevices().map(\.name) }
    default:
      held = active
      let page = SettingsPageAudio()
      keptObjects.append(page)
      var built = NSView()
      ask = { built = page.getView() }
      applied = {
        let popUp = popUps(in: built).first { $0.itemArray.first?.representedObject is MPVAudioDevice }
        return names(popUp) == active.getAudioDevices().map(\.name)
      }
    }
    defer { cleanUp() }
    let returnedWhileHeld = try await returnsWhileHeld(held, ask)
    #expect(returnedWhileHeld, "Asking for \(request) waited for mpv")
    try await waitUntil(applied)
  }

  /// Ask `request` for the path of a new config file of a free name and then of a taken one while `Utility.workspaceQueue` is held,
  /// expecting it to return before the file system is read, then let the queue go and expect the path of the free name to be handed
  /// over, and the file of the taken name to be shown in Finder once the panel asking whether to show it is answered, the panel's
  /// answer returning before LaunchServices is asked.
  private static func checkNewConfigFile(_ request: DeviceOrFileRequest) async throws {
    let name = "iinaTests-\(UUID().uuidString)"
    let taken = Utility.userInputConfDirURL.appendingPathComponent("\(name)-taken.conf")
    try Data().write(to: taken)
    defer { try? FileManager.default.removeItem(at: taken) }
    // The panel asking whether to show the file of a taken name is a sheet on the window of the site.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered,
                          defer: false)
    window.isReleasedWhenClosed = false
    let ask: (String, @escaping (String) -> Void) -> Void
    if request == .prefNewConfigFile {
      let controller = PrefKeyBindingViewController()
      keptObjects.append(controller)
      window.contentViewController = controller
      ask = { controller.newConfigFilePath(forName: $0, then: $1) }
    } else {
      let editor = ConfigEditor()
      keptObjects.append(editor)
      window.contentView = editor.view
      ask = { editor.newConfigFilePath(forName: $0, then: $1) }
    }
    window.orderFront(nil)
    defer { window.close() }
    let recorder = WorkspaceRecorder()
    let make = Utility.makeWorkspaceRequest
    Utility.makeWorkspaceRequest = recorder.record
    defer { Utility.makeWorkspaceRequest = make }

    var path: String?
    var hold = QueueHold(Utility.workspaceQueue, limit: holdLimit)
    ask(name) { path = $0 }
    let freeReturned = !hold.limitPassed && path == nil
    hold.release()
    #expect(freeReturned, "Asking \(request) for a new config file of a free name waited for the file system")
    try await waitUntil { path != nil }
    #expect(path == Utility.userInputConfDirURL.appendingPathComponent("\(name).conf").path)

    path = nil
    hold = QueueHold(Utility.workspaceQueue, limit: holdLimit)
    ask("\(name)-taken") { path = $0 }
    let takenReturned = !hold.limitPassed && window.attachedSheet == nil
    hold.release()
    #expect(takenReturned, "Asking \(request) for a new config file of a taken name waited for the file system")
    try await waitUntil { window.attachedSheet != nil }
    let sheet = try #require(window.attachedSheet)
    hold = QueueHold(Utility.workspaceQueue, limit: holdLimit)
    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    // What answering the panel does on the main thread is done before the requests are looked at.
    await drainMain()
    let answerReturned = !hold.limitPassed && recorder.requests.isEmpty
    hold.release()
    #expect(answerReturned, "Answering \(request)'s panel to show the config file of a taken name waited for LaunchServices")
    await withCheckedContinuation { continuation in Utility.workspaceQueue.async { continuation.resume() } }
    #expect(recorder.requests == [.revealInFinder([URL(fileURLWithPath: taken.path)])])
    #expect(path == nil)
  }

  /// A site that reads mpv's title, tags, chapters, A-B loop, full screen state, window scale, rotation or configured options, or that
  /// is reached through one: each takes what mpv reported in place of waiting for mpv on the main thread.
  enum ReportedValueRequest: String, CaseIterable, Sendable {
    case mediaTitle, windowTitle, titleBar, jsTitle, nowPlaying, trackListChanged, musicMetadata, miniPlayerTitle
    case toolBarMusicMode, commandMusicMode, menuMusicMode, miniPlayerBack, miniPlayerCommand, fullscreenChanged
    case windowScaleChanged, abLoopA, abLoopB, abLoopActive, playbackMenu, jsChapters, rotation, openWithConfiguredOptions
    case frameFromGeometry
  }

  @Test("Each read of mpv's title, tags, chapters, A-B loop, full screen state, window scale, rotation or configured options takes what mpv reported and returns before mpv is asked, then does what the site was asked",
        arguments: ReportedValueRequest.allCases)
  func reportedValueDoesNotWait(_ request: ReportedValueRequest) async throws {
    switch request {
    case .openWithConfiguredOptions, .frameFromGeometry:
      try await Self.checkConfiguredOptions(request)
    default:
      try await Self.withPlayer { player, folder in
        try await Self.checkReportedValueRequest(request, player: player, folder: folder)
      }
    }
  }

  /// Make `request` while the core of the `mpv` it reads is held, or for the title bar while `Utility.workspaceQueue` is held,
  /// expecting it to return before `mpv` or the file system answers, then let the core or the queue go and expect the site to have done
  /// what it was asked.
  /// - Parameter player: The player playing `b.mp4` of `folder`.
  private static func checkReportedValueRequest(_ request: ReportedValueRequest, player: PlayerCore, folder: URL) async throws {
    let mpv: MPVController = player.mpv
    let window: MainWindowController = player.mainWindow
    let miniPlayer: MiniPlayerWindowController = player.miniPlayer
    // A title the file does not have, which mpv reports as the media title once it is forced, so that a site showing it shows the title
    // mpv reported.
    let title = "iinaTests-\(UUID().uuidString)"
    mpv.setString(MPVOption.Miscellaneous.forceMediaTitle, title)
    try await waitUntil { player.info.mediaTitle == title }
    let defaults = UserDefaults.standard
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    // A change of a setting is told to its observers when the settings are next read, on the thread reading them, and a window takes
    // a change of some settings with AppKit, so each change is read at once on the main thread.
    func withSetting(_ key: Preference.Key, _ value: Any) {
      defaults.setVolatileDomain(defaults.volatileDomain(forName: UserDefaults.argumentDomain).merging([key.rawValue: value]) { $1 },
                                 forName: UserDefaults.argumentDomain)
      _ = defaults.object(forKey: key.rawValue)
    }
    defer {
      defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
      _ = defaults.object(forKey: Preference.Key.useLegacyFullScreen.rawValue)
    }
    func pluginInstance() throws -> JavascriptPluginInstance {
      // A plugin's script is read when its instance is made, so the instance is made before the core is held. The plugin is kept,
      // since its instance holds it weakly and reads it when the instance is let go.
      let plugin = try makePlugin(in: folder)
      keptPlugins.append(plugin)
      return JavascriptPluginInstance(player: player, plugin: plugin)
    }
    let ask: () -> Void
    let applied: () -> Bool
    var cleanUp: () async throws -> Void = {}
    var held = player
    switch request {
    case .titleBar:
      // The name and icon of a local file are read off the main thread, so the title stays as it was until the queue reading them is
      // let go.
      let titleBar = try #require(window.titleBarView)
      let field = try #require(titleBar.titleTextField)
      field.stringValue = ""
      let hold = QueueHold(Utility.workspaceQueue, limit: holdLimit)
      titleBar.updateTitle()
      let returnedWhileHeld = !hold.limitPassed && field.stringValue.isEmpty
      hold.release()
      #expect(returnedWhileHeld, "Showing the title bar's title waited for the file system")
      let path = try #require(player.info.currentURL).path
      try await waitUntil { field.stringValue == FileManager.default.displayName(atPath: path) && titleBar.docIcon.image != nil }
      return
    case .mediaTitle:
      var read = ""
      ask = { read = player.getMediaTitle() }
      applied = { read == title }
    case .windowTitle:
      // The window shows the media title of a stream read over the network.
      player.info.isNetworkResource = true
      cleanUp = {
        player.info.isNetworkResource = false
        window.updateTitle()
      }
      ask = { window.updateTitle() }
      applied = { window.window?.title == title && window.titleBarView.titleTextField.stringValue == title }
    case .jsTitle:
      let instance = try pluginInstance()
      var read: String?
      ask = { read = instance.js.evaluateScript("iina.core.status.title")?.toString() }
      applied = { read == title }
    case .nowPlaying, .trackListChanged:
      // Now Playing is given the title at once while the time is kept up to date.
      withSetting(.enableNowPlayingArtwork, false)
      let useSystemMediaControl = RemoteCommandController.useSystemMediaControl
      RemoteCommandController.useSystemMediaControl = true
      PlayerCore.lastActive = player
      if player.syncUITimer?.isValid != true {
        player.syncUITimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { _ in }
      }
      cleanUp = {
        player.syncUITimer?.invalidate()
        RemoteCommandController.useSystemMediaControl = useSystemMediaControl
      }
      let center = MPNowPlayingInfoCenter.default()
      center.nowPlayingInfo = [MPMediaItemPropertyTitle: ""]
      if request == .nowPlaying {
        ask = { NowPlayingInfoManager.shared.updateInfo(withTitle: true) }
      } else {
        let trackList = player.readTrackList(), selectedTracks = player.readSelectedTracks()
        ask = { player.trackListChanged(trackList, selectedTracks) }
      }
      applied = { center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == title }
    case .musicMetadata:
      var read: (title: String, album: String, artist: String)?
      ask = { read = player.getMusicMetadata() }
      // The test files have no tags.
      applied = { read.map { $0.title == title && $0.album.isEmpty && $0.artist.isEmpty } ?? false }
    case .miniPlayerTitle:
      _ = miniPlayer.window
      miniPlayer.titleLabel.stringValue = ""
      ask = { miniPlayer.updateTitle() }
      applied = { miniPlayer.titleLabel.stringValue == title }
    case .toolBarMusicMode, .commandMusicMode, .menuMusicMode:
      let button = NSButton()
      button.tag = Preference.ToolBarButton.musicMode.rawValue
      ask = request == .toolBarMusicMode ? { window.toolBarButtonAction(button) }
        : request == .commandMusicMode ? { window.handleIINACommand(.toggleMusicMode) } : { window.menuSwitchToMiniPlayer(.dummy) }
      applied = { player.isInMiniPlayer && miniPlayer.titleLabel.stringValue == title }
      cleanUp = {
        player.switchBackFromMiniPlayer()
        try await waitUntil { !player.isInMiniPlayer }
      }
    case .miniPlayerBack, .miniPlayerCommand:
      player.switchToMiniPlayer()
      try await waitUntil { player.isInMiniPlayer }
      // The window shown again shows the media title of a stream read over the network.
      player.info.isNetworkResource = true
      cleanUp = {
        player.info.isNetworkResource = false
        window.updateTitle()
      }
      ask = request == .miniPlayerBack ? { miniPlayer.backBtnAction(NSButton()) } : { miniPlayer.handleIINACommand(.toggleMusicMode) }
      applied = { !player.isInMiniPlayer && window.window?.isVisible == true && window.window?.title == title }
    case .fullscreenChanged:
      // Legacy full screen is entered in the window itself, without the space AppKit's full screen makes.
      withSetting(.useLegacyFullScreen, true)
      ask = { player.fullscreenChanged(true) }
      applied = { window.fsState.isFullscreen }
      func inFullScreen() -> Bool {
        if case .fullscreen = window.fsState { return true }
        return false
      }
      cleanUp = {
        try await waitUntil(inFullScreen)
        window.toggleWindowFullScreen()
        try await waitUntil { window.fsState == .windowed }
      }
    case .windowScaleChanged:
      // The file is 64 by 48 pixels, so the window is at its least size before the scale is asked for and larger after.
      let before = try #require(window.window).frame
      ask = { player.windowScaleChanged(10) }
      applied = { (window.window?.frame.width ?? 0) > before.width + 1 }
    case .abLoopA, .abLoopB, .abLoopActive, .playbackMenu:
      // The menu shows the active player, the player of the main window or else the first player.
      let looping = request == .playbackMenu ? PlayerCore.active : player
      held = looping
      // Both loop points are set, which mpv reports.
      looping.mpv.setDouble(MPVOption.PlaybackControl.abLoopA, 1)
      looping.mpv.setDouble(MPVOption.PlaybackControl.abLoopB, 2)
      try await waitUntil { looping.info.abLoopA == 1 && looping.info.abLoopB == 2 }
      cleanUp = {
        looping.mpv.setString(MPVOption.PlaybackControl.abLoopA, "no")
        looping.mpv.setString(MPVOption.PlaybackControl.abLoopB, "no")
      }
      switch request {
      case .abLoopA, .abLoopB:
        var read = 0.0
        ask = request == .abLoopA ? { read = player.abLoopA } : { read = player.abLoopB }
        applied = { read == (request == .abLoopA ? 1 : 2) }
      case .abLoopActive:
        var read = false
        ask = { read = player.isABLoopActive }
        applied = { read }
      default:
        let menuController = try #require(AppDelegate.shared.menuController)
        menuController.abLoop.state = .off
        ask = { menuController.menuWillOpen(menuController.playbackMenu) }
        applied = { menuController.abLoop.state == .on }
      }
    case .jsChapters:
      // The test files have no chapters, so the player is given one, as if mpv had reported it.
      player.info.chapters = [MPVChapter(title: "iinaTests", startTime: 2, index: 0)]
      let instance = try pluginInstance()
      var read: [Any]?
      ask = { read = instance.js.evaluateScript("iina.core.getChapters()")?.toArray() }
      applied = { (read?.first as? [String: Any])?["title"] as? String == "iinaTests" }
    case .rotation:
      var read = -1
      ask = { read = window.rotation }
      applied = { read == player.info.videoParamsRotation }
    case .openWithConfiguredOptions, .frameFromGeometry:
      Issue.record("\(request) is checked in a player of its own")
      return
    }
    let returnedWhileHeld = try await returnsWhileHeld(held, ask)
    #expect(returnedWhileHeld, "Asking for \(request) waited for mpv")
    try await waitUntil(applied)
    try await cleanUp()
  }

  /// Open `b.mp4` of a new folder in a new player whose mpv is configured to ignore paths in watch later files and to size windows by a
  /// geometry, then ask `request` while the core of its `mpv` is held, expecting it to return before `mpv` answers, let the core go and
  /// expect the options `mpv` answered to have been used.
  ///
  /// For `openWithConfiguredOptions` the core is held from just after `mpv` is initialized until the open has reached the main thread.
  private static func checkConfiguredOptions(_ request: ReportedValueRequest) async throws {
    let defaults = UserDefaults.standard
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    let options = [[MPVOption.WatchLater.ignorePathInWatchLaterConfig, "yes"], [MPVOption.Window.geometry, "50%x50%"]]
    let configured: [String: Any] = [Preference.Key.enableAdvancedSettings.rawValue: true,
                                     Preference.Key.userOptions.rawValue: options]
    defaults.setVolatileDomain(arguments.merging(settings) { $1 }.merging(configured) { $1 }, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("b.mp4")

    let player = PlayerCore()
    // Like PlayerCore.createPlayerCore, label the player before it logs anything, since its log subsystem is named after it.
    player.label = "iinaTests-playback-\(playerCount)"
    playerCount += 1
    player.startMPV()
    current = player
    defer { current = nil }
    // The window is loaded before the core is held, so that the open is all that is asked while it is held.
    _ = player.mainWindow.window
    if request == .openWithConfiguredOptions {
      let hold = try MPVCoreHold(player.mpv, limit: holdLimit)
      player.openURL(url)
      // The player is told of the file on the main thread, once the open has made its URL off it.
      try await waitUntil { player.info.currentURL != nil || hold.hasLetGo }
      let openedWhileHeld = !hold.hasLetGo
      hold.release()
      try await waitUntil { hold.hasLetGo }
      #expect(openedWhileHeld, "Opening a file in a new player waited for mpv")
    } else {
      player.openURL(url)
    }
    do {
      try await waitUntil { player.info.state == .paused && player.mpv.getInt(MPVProperty.playlistCount) == 3 }
      #expect(player.ignorePathInWatchLaterConfig)
      #expect(player.info.mpvMd5 == Utility.mpvWatchLaterMd5(url, true))
      if request == .frameFromGeometry {
        try await checkFrameFromGeometry(player)
      }
    } catch {
      player.mainWindow.close()
      throw error
    }
    player.mainWindow.close()
    try await waitUntil { player.info.state == .idle }
  }

  /// Size the window of `player` by the geometry option while the core of its `mpv` is held, expecting the size to be worked out
  /// before `mpv` answers, then let the core go and expect the size to be the half of the screen the geometry asks for.
  private static func checkFrameFromGeometry(_ player: PlayerCore) async throws {
    let window: MainWindowController = player.mainWindow
    // The geometry is read when a window sizes itself for the first time, so the window is made to read it again.
    window.cachedGeometry = nil
    var frame: NSRect?
    let returnedWhileHeld = try await returnsWhileHeld(player) {
      frame = window.windowFrameFromGeometry(newSize: NSSize(width: 64, height: 48))
    }
    #expect(returnedWhileHeld, "Sizing the window by the geometry option waited for mpv")
    let screen = try #require(window.window?.screen).visibleFrame
    // The geometry asks for half the screen's width and height, of which the window keeps the file's aspect.
    let sized = try #require(frame)
    #expect(abs(sized.width - screen.width / 2) < 1 || abs(sized.height - screen.height / 2) < 1)
  }

  /// A read the inspector makes of the player it shows: each must not wait for mpv on the main thread.
  enum InspectorRequest: String, CaseIterable, Sendable {
    case info, dynamicInfo, watchedProperties
  }

  @Test("Each read the inspector makes of mpv is asked in requests that do not wait for mpv, and what mpv answers is shown",
        arguments: InspectorRequest.allCases)
  func inspectorDoesNotWait(_ request: InspectorRequest) async throws {
    try await Self.withPlayer { player, _ in
      PlayerCore.lastActive = player
      let inspector = InspectorWindowController()
      Self.keptObjects.append(inspector)
      inspector.showWindow(nil)
      defer { inspector.close() }
      // The inspector first shows what it read when it was shown.
      let length = VideoTime(4).stringRepresentation
      try await Self.waitUntil { inspector.durationField.stringValue == length }
      let path = try #require(player.info.currentURL).path
      let ask: () -> Void
      let shown: () -> Bool
      switch request {
      case .info:
        inspector.pathField.stringValue = ""
        inspector.vsizeField.stringValue = ""
        ask = { inspector.updateInfo() }
        shown = { inspector.pathField.stringValue == path && inspector.vsizeField.stringValue == "64\u{d7}48" }
      case .dynamicInfo:
        inspector.vbitrateField.stringValue = ""
        ask = { inspector.updateInfo(dynamic: true) }
        shown = { inspector.vbitrateField.stringValue.hasSuffix("bps") }
      case .watchedProperties:
        // The path as mpv has it, read before its core is held.
        let watched = try #require(player.mpv.getString(MPVProperty.path))
        inspector.watchProperties = [MPVProperty.path]
        inspector.watchTableView.reloadData()
        let column = inspector.watchTableView.column(withIdentifier: .value)
        ask = { inspector.dynamicUpdate() }
        shown = {
          let cell = inspector.watchTableView.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView
          return cell?.textField?.stringValue == watched
        }
      }
      // The inspector shows what it reads on the main thread, so the core is held until the main thread has run what the request
      // gave it.
      let hold = try MPVCoreHold(player.mpv, limit: Self.holdLimit)
      ask()
      await Self.drainMain()
      let returnedWhileHeld = !hold.hasLetGo
      hold.release()
      try await Self.waitUntil { hold.hasLetGo }
      #expect(returnedWhileHeld, "The inspector's \(request) waited for mpv")
      try await Self.waitUntil(shown)
    }
  }

  /// A set, command or hook a plugin asks of mpv, or a hook the player adds: each must not wait for mpv on the main thread.
  enum PluginMpvRequest: String, CaseIterable, Sendable {
    case jsSetNumber, jsSetString, jsSetFlag, jsSetObject, jsCommand, jsAddHook, addHook
  }

  @Test("Each set, command or hook a plugin or the player asks of mpv returns before mpv handles it, which then does what was asked",
        arguments: PluginMpvRequest.allCases)
  func pluginMpvRequestDoesNotWait(_ request: PluginMpvRequest) async throws {
    try await Self.withPlayer { player, folder in
      let mpv: MPVController = player.mpv
      // A plugin's script is read when its instance is made, so the instance is made before the core is held. The plugin is kept,
      // since its instance holds it weakly and reads it when the instance is let go.
      let plugin = try Self.makePlugin(in: folder, permissions: ["file-system"])
      Self.keptPlugins.append(plugin)
      let instance = JavascriptPluginInstance(player: player, plugin: plugin)
      func script(_ source: String) -> () -> Void {
        { _ = instance.js.evaluateScript(source) }
      }
      let ask: () -> Void
      let applied: () -> Bool
      // Set by the player's hook, which mpv runs on the queue for reading its events.
      let hooked = Atomic(wrappedValue: false)
      switch request {
      case .jsSetNumber:
        ask = script("iina.mpv.set('speed', 2)")
        applied = { mpv.getDouble(MPVOption.PlaybackControl.speed) == 2 }
      case .jsSetString:
        ask = script("iina.mpv.set('loop-file', 'inf')")
        applied = { mpv.getString(MPVOption.PlaybackControl.loopFile) == "inf" }
      case .jsSetFlag:
        ask = script("iina.mpv.set('mute', true)")
        applied = { mpv.getFlag(MPVOption.Audio.mute) }
      case .jsSetObject:
        ask = script("iina.mpv.set('user-data/iinaTests', {answer: 'yes'})")
        applied = { (mpv.getNode("user-data/iinaTests") as? [String: Any])?["answer"] as? String == "yes" }
      case .jsCommand:
        ask = script("iina.mpv.command('set', ['speed', '1.5'])")
        applied = { mpv.getDouble(MPVOption.PlaybackControl.speed) == 1.5 }
      case .jsAddHook:
        // A hook mpv runs when the next entry starts, which marks that it ran.
        ask = script("iina.mpv.addHook('on_before_start_file', 0, () => { globalThis.iinaTestsHooked = true })")
        applied = { instance.js.evaluateScript("globalThis.iinaTestsHooked === true")?.toBool() == true }
      case .addHook:
        ask = { mpv.addHook(.onBeforeStartFile, hook: MPVHookValue(withBlock: { next in hooked.withLock { $0 = true }; next() })) }
        applied = { hooked.withLock { $0 } }
      }
      let returnedWhileHeld = try await Self.returnsWhileHeld(player, ask)
      #expect(returnedWhileHeld, "Asking for \(request) waited for mpv")
      if request == .jsAddHook || request == .addHook {
        player.navigateInPlaylist(nextMedia: true)
      }
      try await Self.waitUntil(applied)
    }
  }

  @Test("A started file's date last opened is written off the main thread, the start returning while the queue writing it is held")
  func fileStartedWritesOffMain() async throws {
    try await Self.withPlayer { player, folder in
      let path = folder.appendingPathComponent("b.mp4").path
      let name = "com.apple.lastuseddate#PS"
      removexattr(path, name, 0)
      func written() -> Bool { getxattr(path, name, nil, 0, 0, 0) > 0 }
      let hold = QueueHold(player.backgroundQueue, limit: Self.holdLimit)
      player.fileStarted(path: path)
      let returnedWhileHeld = !hold.limitPassed && !written()
      hold.release()
      #expect(returnedWhileHeld, "Starting a file wrote its date last opened on the main thread")
      try await Self.waitUntil(written)
      #expect(player.info.currentURL == URL(fileURLWithPath: path))
    }
  }

  /// Run `request`, which asks for the thumbnails of the player's file, while the core of the player's `mpv` and the queue the player
  /// checks the file system for thumbnails on are held, the thumbnails being asked of FFmpeg rather than read from a cache.
  /// - Returns: Whether `request` returned while both were held, before FFmpeg was asked for the thumbnails, which a request that
  ///   waits for `mpv` or reads the file system on the calling thread cannot do. FFmpeg has been asked once both are let go.
  private static func thumbnailsAskedOffMain(_ player: PlayerCore, _ request: () -> Void) async throws -> Bool {
    let queue = try #require(player.ffmpegController.value(forKey: "queue") as? OperationQueue)
    player.ffmpegController.cancelThumbnailGeneration()
    queue.isSuspended = true
    defer {
      player.ffmpegController.cancelThumbnailGeneration()
      queue.isSuspended = false
    }
    func asked() -> Bool { queue.operations.contains { !$0.isCancelled } }
    // A cache name no cache file has, so that the thumbnails are asked of FFmpeg.
    player.info.mpvMd5 = UUID().uuidString
    let hold = QueueHold(player.thumbnailQueue, limit: holdLimit)
    var askedWhileHeld = true
    let returnedWhileHeld = try await returnsWhileHeld(player) {
      request()
      askedWhileHeld = asked()
    }
    let checkedOffMain = returnedWhileHeld && !hold.limitPassed && !askedWhileHeld
    hold.release()
    try await waitUntil(asked)
    return checkedOffMain
  }

  @Test("A file's thumbnails are asked for without the main thread reading the file system: its volume and cache are checked on the player's thumbnail queue, then FFmpeg is asked")
  func thumbnailsCheckedOffMain() async throws {
    try await Self.withPlayer { player, _ in
      try await Self.withSettings([.enableThumbnailPreview: true, .enableThumbnailForRemoteFiles: false]) {
        let checkedOffMain = try await Self.thumbnailsAskedOffMain(player) { player.generateThumbnails() }
        #expect(checkedOffMain, "Asking for a file's thumbnails read the file system on the main thread")
      }
    }
  }

  @Test("A video size change the window handles first asks for the thumbnails without waiting for mpv or the file system")
  func videoSizeChangeAsksThumbnailsOffMain() async throws {
    try await Self.withPlayer { player, _ in
      try await Self.withSettings([.enableThumbnailPreview: true, .enableThumbnailForRemoteFiles: false]) {
        // The window asks for the thumbnails when it first loads video, as it does for a player that is not loading an entry.
        player.mainWindow.isVideoLoaded = false
        let checkedOffMain = try await Self.thumbnailsAskedOffMain(player) {
          player.mainWindow.handleVideoSizeChange(keepWindowSize: true)
        }
        #expect(checkedOffMain, "Handling a video size change waited for mpv or read the file system on the main thread")
        #expect(player.mainWindow.isVideoLoaded)
      }
    }
  }

  /// Plugins whose instances a test makes, kept for as long as the instances may read them.
  private static var keptPlugins: [JavascriptPlugin] = []

  /// Write `<name>.wav`, a second of silence, in `folder`.
  /// - Returns: The file written.
  private static func writeSilence(_ name: String, in folder: URL) throws -> URL {
    let rate: UInt32 = 8000
    let samples = Data(count: Int(rate) * 2)
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + samples.count))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    // 16-bit mono PCM.
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(rate)
    append(rate * 2)
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(samples.count))
    data.append(samples)
    let file = folder.appendingPathComponent("\(name).wav")
    try data.write(to: file)
    return file
  }

  @Test("A request the player makes without waiting is answered only once the core MPVCoreHold holds is let go")
  func coreHoldDefersAnswers() async throws {
    try await Self.withPlayer { player, _ in
      let hold = try MPVCoreHold(player.mpv, limit: Self.holdLimit)
      let letGoWhenAnswered = MainReply<Bool>()
      player.mpv.getNodesAsync([MPVProperty.timePos]) { _ in letGoWhenAnswered.set(hold.hasLetGo) }
      try await Task.sleep(for: Self.heldAnswerWindow)
      #expect(letGoWhenAnswered.value == nil, "mpv answered while its core was held")
      #expect(!hold.hasLetGo, "The core was let go before it was released")
      hold.release()
      try await Self.waitUntil { letGoWhenAnswered.value != nil }
      #expect(letGoWhenAnswered.value == true)
    }
  }

  @Test("A file the player moves to is stored as it was read when mpv reported it loaded, and its entry is then marked current")
  func fileLoadedFromEvent() async throws {
    try await Self.withPlayer { player, folder in
      var stored: (path: String?, width: Int?, duration: Double?, vid: Int?)?
      // The player reports the file loaded once fileLoaded has stored it.
      player.observe(.iinaFileLoaded) { [unowned player] _ in
        stored = (player.info.currentURL?.path, player.info.videoWidth, player.info.videoDuration?.second, player.info.vid)
      }
      player.playFileInPlaylist(2)
      try await Self.waitUntil { stored != nil }
      #expect(stored?.path == folder.appendingPathComponent("c.mp4").path)
      #expect(stored?.width == player.mpv.getInt(MPVProperty.width))
      // mpv's duration of a fragmented file grows as it reads the fragments, so only its presence at load is checked.
      #expect((stored?.duration ?? 0) > 0)
      #expect(stored?.vid == player.mpv.getInt(MPVOption.TrackSelection.vid))
      // fileLoaded asks mpv for the playlist, whose answer marks the entry loaded as current.
      try await Self.waitUntil { player.info.playlist.map(\.isCurrent) == [false, false, true] }
    }
  }

  @Test("Now Playing is given the position mpv answers, asked without waiting for mpv while the time is not kept up to date")
  func nowPlayingPositionDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      try await Self.withSettings([.enableNowPlayingArtwork: false]) {
        let useSystemMediaControl = RemoteCommandController.useSystemMediaControl
        RemoteCommandController.useSystemMediaControl = true
        defer { RemoteCommandController.useSystemMediaControl = useSystemMediaControl }
        PlayerCore.lastActive = player
        player.seek(percent: 50, forceExact: true)
        try await Self.waitForPosition(2, of: player)
        player.syncUITimer?.invalidate()
        // A position mpv does not hold shows that Now Playing is given the one mpv answers.
        player.info.videoPosition = VideoTime(0)
        let returnedWhileHeld = try await Self.returnsWhileHeld(player) {
          NowPlayingInfoManager.shared.updateInfo(withTitle: true)
        }
        #expect(returnedWhileHeld, "Updating Now Playing waited for mpv")
        try await Self.waitUntil {
          let elapsed = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
          return abs((elapsed ?? 0) - 2) < 0.11
        }
      }
    }
  }

  @Test("Files added to the playlist are listed by the playlist read their change notice asks for, though asked before mpv adds them")
  func addToPlaylistReadBack() async throws {
    try await Self.withPlayer { player, folder in
      let path = { (name: String) in folder.appendingPathComponent("\(name).mp4").path }
      var reads: [[String]] = []
      // As the playlist pane does, the playlist is read each time the player reports it changed.
      player.observe(.iinaPlaylistChanged) { [unowned player] _ in
        player.getPlaylist { reads.append(player.info.playlist.map(\.filename)) }
      }
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { player.addToPlaylist(paths: [path("d")], at: 1) }
      #expect(returnedWhileHeld, "Adding files waited for mpv")
      // mpv answers in the order it is asked, so the read asked for after the add lists the file added.
      try await Self.waitUntil { !reads.isEmpty }
      #expect(reads.first == ["a", "d", "b", "c"].map(path))
    }
  }

  @Test("The playlist pane lists mpv's playlist once the read a change notice asks for is answered, the read not waiting for mpv")
  func playlistPaneUpdated() async throws {
    try await Self.withPlayer { player, folder in
      let pane = SidebarPlaylistPane(player: player)
      try await Self.waitUntil { pane.tableView.numberOfRows == 3 }
      // The pane reads the playlist when the add reports it changed, so the add returning while held shows the read does not wait.
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) {
        player.addToPlaylist(paths: [folder.appendingPathComponent("d.mp4").path])
      }
      #expect(returnedWhileHeld, "The playlist pane's read waited for mpv")
      try await Self.waitUntil { pane.tableView.numberOfRows == 4 }
    }
  }

  @Test("A file the system asks the app to open just after a command-line launch is not opened, and one asked after it is")
  func systemOpenIgnoredOnce() async throws {
    try await Self.withPlayer { _, folder in
      try await Self.withSettings([.alwaysOpenInNewWindow: true, .groupSimultaneousOpensInPlaylist: false,
                                   .allowDuplicatePlayers: false]) {
        let app = AppDelegate.shared
        let video = folder.appendingPathComponent("c.mp4")
        app.shouldIgnoreOpenFile = true
        #expect(app.application(NSApp, openFile: video.path))
        try await Self.waitUntil { !app.shouldIgnoreOpenFile }
        await Self.drainMain()
        #expect(!PlayerCore.playerCores.contains { $0.info.currentURL?.path == video.path })
        #expect(app.application(NSApp, openFile: video.path))
        let players = try await Self.players(showing: [video.path])
        #expect(PlayerCore.playerCores.filter { $0.info.currentURL?.path == video.path }.count == 1)
        try await Self.close(players)
      }
    }
  }

  @Test("A file the system asks the app to open that is not played on its own is reported as nothing to open")
  func systemOpenNothing() async throws {
    try await Self.withPlayer { _, folder in
      try await Self.withSettings([.alwaysOpenInNewWindow: true]) {
        // A subtitle file is not opened on its own, so the open finds no file to play.
        let file = folder.appendingPathComponent("a.srt")
        try "IINA".write(to: file, atomically: true, encoding: .utf8)
        let dismisser = ModalWindowDismisser()
        defer { dismisser.stop() }
        #expect(AppDelegate.shared.application(NSApp, openFile: file.path))
        let message = NSLocalizedString("alert.nothing_to_open", comment: "nothing_to_open")
        try await Self.waitUntil { !dismisser.texts.isEmpty }
        #expect(dismisser.texts.contains { $0.contains(message) }, "The alerts shown read \(dismisser.texts)")
      }
    }
  }

  @Test("A plugin package the system asks the app to open is handed to the plugin settings, which report one that cannot be read")
  func systemOpenPlugin() async throws {
    try await Self.withPlayer { _, folder in
      try await Self.withSettings([.enableNewSettings: true]) {
        let package = folder.appendingPathComponent("iinaTests.iinaplgz")
        try "IINA".write(to: package, atomically: true, encoding: .utf8)
        let settings = SettingsWindow.default
        #expect(AppDelegate.shared.application(NSApp, openFile: package.path))
        // The package cannot be unpacked, which the plugin settings report in a sheet on their window.
        try await Self.waitUntil { settings.isVisible && settings.attachedSheet != nil }
        #expect(!PlayerCore.playerCores.contains { $0.info.currentURL?.path == package.path })
        if let sheet = settings.attachedSheet {
          settings.endSheet(sheet)
        }
        settings.close()
      }
    }
  }

  /// A plugin in `folder` with `permissions` and `author` whose script does nothing, in whose context a test evaluates scripts.
  private static func makePlugin(in folder: URL, permissions: [String] = [],
                                 author: [String: String] = ["name": "iinaTests"]) throws -> JavascriptPlugin {
    let root = folder.appendingPathComponent("iinaTests-plugin")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let info: [String: Any] = ["name": "iinaTests", "author": author, "identifier": "io.iina.tests",
                               "version": "1.0", "entry": "main.js", "permissions": permissions]
    try JSONSerialization.data(withJSONObject: info).write(to: root.appendingPathComponent("Info.json"))
    try Data().write(to: root.appendingPathComponent("main.js"))
    return try #require(JavascriptPlugin(filename: root.lastPathComponent, externalURL: root))
  }

  /// Write a subtitle file `<name>.srt` holding one line in `folder` for each of `names`.
  /// - Returns: The files written, in the order of `names`.
  private static func writeSubtitles(_ names: [String], in folder: URL) throws -> [URL] {
    try names.map { name in
      let file = folder.appendingPathComponent("\(name).srt")
      try "1\n00:00:00,000 --> 00:00:04,000\n\(name)\n".write(to: file, atomically: true, encoding: .utf8)
      return file
    }
  }

  @Test("A plugin's status position and duration are answered at once, the position being the one mpv holds while the time is not kept up to date")
  func statusPositionAndDuration() async throws {
    try await Self.withPlayer { player, folder in
      player.seek(percent: 50, forceExact: true)
      try await Self.waitForPosition(2, of: player)
      player.syncUITimer?.invalidate()
      let plugin = try Self.makePlugin(in: folder)
      let instance = JavascriptPluginInstance(player: player, plugin: plugin)
      // A position mpv does not hold shows whether the getter answers with the position mpv holds.
      player.info.videoPosition = VideoTime(0)
      let position = try #require(instance.js.evaluateScript("iina.core.status.position")).toDouble()
      #expect(abs(position - 2) < 0.11)
      #expect(player.info.videoPosition?.second == position)
      let duration = try #require(instance.js.evaluateScript("iina.core.status.duration")).toDouble()
      #expect(duration == player.info.videoDuration?.second)
    }
  }

  @Test("Jump to returns while mpv's core is held, then shows its prompt filled with the position mpv answers, and a prompt dismissed seeks nowhere")
  func jumpToDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      player.seek(percent: 50, forceExact: true)
      try await Self.waitForPosition(2, of: player)
      player.syncUITimer?.invalidate()
      // A position mpv does not hold shows whether the prompt is filled with the position mpv answers.
      player.info.videoPosition = VideoTime(0)
      let prompt = ModalWindowDismisser()
      defer { prompt.stop() }
      let handler = MainMenuActionHandler(playerCore: player)
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) { handler.menuJumpTo(NSMenuItem()) }
      #expect(returnedWhileHeld, "Jump to waited for mpv")
      try await Self.waitUntil { !prompt.texts.isEmpty }
      let position = try #require(player.info.videoPosition)
      #expect(abs(position.second - 2) < 0.11)
      #expect(prompt.texts[0].contains(position.stringRepresentationWithPrecision(3)), "The prompt read \(prompt.texts)")
      await Self.drainMain()
      #expect(abs(player.mpv.getDouble(MPVProperty.timePos) - 2) < 0.11)
    }
  }

  @Test("A time entered in the jump to prompt is sought")
  func jumpToSeeks() async throws {
    try await Self.withPlayer { player, _ in
      player.syncUITimer?.invalidate()
      let prompt = ModalWindowDismisser(entering: "00:01")
      defer { prompt.stop() }
      MainMenuActionHandler(playerCore: player).menuJumpTo(NSMenuItem())
      try await Self.waitUntil { !prompt.texts.isEmpty }
      try await Self.waitForPosition(1, of: player)
    }
  }

  @Test("The chapter menu is built at once and checks the chapter playing once the position mpv answers is stored, the read not waiting for mpv")
  func chapterMenuDoesNotWait() async throws {
    try await Self.withPlayer { player, _ in
      let menuController = try #require(AppDelegate.shared.menuController)
      player.info.chapters = [MPVChapter(title: "One", startTime: 0, index: 0), MPVChapter(title: "Two", startTime: 2, index: 1)]
      player.seek(absoluteSecond: 3)
      try await Self.waitForPosition(3, of: player)
      player.syncUITimer?.invalidate()
      // A position mpv does not hold, in the first chapter, shows whether the chapter checked is the one mpv answers playback is in.
      player.info.videoPosition = VideoTime(0)
      var listedWhileHeld: [Int] = []
      let returnedWhileHeld = try await Self.returnsWhileHeld(player) {
        menuController.updateChapterList(of: player)
        listedWhileHeld = menuController.chapterMenu.items.map(\.tag)
      }
      #expect(returnedWhileHeld, "Building the chapter menu waited for mpv")
      #expect(listedWhileHeld == [0, 1])
      let items = menuController.chapterMenu.items
      try await Self.waitUntil { items.map(\.state) == [.off, .on] }
    }
  }

  @Test("Files chosen in the Open panel none of which is played on its own are reported as nothing to open once they are found, and a video chosen opens")
  func openChosenFiles() async throws {
    try await Self.withPlayer { _, folder in
      try await Self.withSettings([.alwaysOpenInNewWindow: true]) {
        let subtitle = try Self.writeSubtitles(["a"], in: folder)[0]
        let dismisser = ModalWindowDismisser()
        defer { dismisser.stop() }
        AppDelegate.shared.openChosenFiles([subtitle])
        // The files are found off the main thread, so nothing is reported when the open returns.
        #expect(dismisser.texts.isEmpty)
        let message = NSLocalizedString("alert.nothing_to_open", comment: "nothing_to_open")
        try await Self.waitUntil { !dismisser.texts.isEmpty }
        #expect(dismisser.texts.contains { $0.contains(message) }, "The alerts shown read \(dismisser.texts)")
        let video = folder.appendingPathComponent("c.mp4")
        AppDelegate.shared.openChosenFiles([video])
        let players = try await Self.players(showing: [video.path])
        #expect(dismisser.texts.count == 1)
        try await Self.close(players)
      }
    }
  }

  @Test("Files named on the command line open each in a new player, the last of which enters music mode once it has opened its file")
  func commandLineMusicMode() async throws {
    try await Self.withPlayer { _, folder in
      let videos = ["a", "c"].map { folder.appendingPathComponent("\($0).mp4") }
      var status = CommandLineStatus()
      status.filenames = videos.map(\.path)
      status.openSeparateWindows = true
      status.enterMusicMode = true
      let entered = NoticeRecorder(.iinaMusicModeChanged)
      defer { entered.stop() }
      AppDelegate.shared.openFromCommandLine(status)
      let players = try await Self.players(showing: videos.map(\.path))
      try await Self.waitUntil { players[1].isInMiniPlayer }
      #expect(!players[0].isInMiniPlayer)
      // The player shows the file it opened as it enters music mode.
      #expect(entered.paths == [videos[1].path])
      players[1].switchBackFromMiniPlayer()
      try await Self.close(players)
    }
  }

  @Test("Files named on the command line open together in a new player, which enters picture-in-picture once it has opened them")
  func commandLinePIP() async throws {
    try await Self.withPlayer { _, folder in
      try await Self.withSettings([.windowBehaviorWhenPip: Preference.WindowBehaviorWhenPip.doNothing.rawValue, .pauseWhenPip: false]) {
        let videos = ["a", "c"].map { folder.appendingPathComponent("\($0).mp4") }
        var status = CommandLineStatus()
        status.filenames = videos.map(\.path)
        status.enterPIP = true
        // The command line opens in an idle player when there is one, so with one made sure of, each player that may open the
        // files tells the path of the file it shows as it enters picture-in-picture.
        _ = PlayerCore.newPlayerCore
        var entered: [String?] = []
        let listeners = PlayerCore.playerCores.map { player in
          let recorder = EventRecorder { data in
            if data.first as? Bool == true {
              entered.append(player.info.currentURL?.path)
            }
          }
          return (player, player.events.addListener(recorder, for: .pipChanged))
        }
        defer { listeners.forEach { player, id in player.events.removeListener(id, for: .pipChanged) } }
        AppDelegate.shared.openFromCommandLine(status)
        let players = try await Self.players(showing: [videos[0].path])
        try await Self.waitUntil { !entered.isEmpty }
        #expect(entered == [videos[0].path])
        // The system may close picture-in-picture without reporting it closed, as on the test machine, where it asks the window to
        // prepare for closing and reports nothing after, so the window is brought out of it as that report would.
        players[0].mainWindow.exitPIP()
        if players[0].mainWindow.pipStatus == .intermediate {
          players[0].mainWindow.doneExitingPIP()
        }
        #expect(players[0].mainWindow.pipStatus == .notInPIP)
        try await Self.close(players)
      }
    }
  }

  @Test("Standard input named on the command line opens in a new player, which enters music mode at once")
  func commandLineStdin() async throws {
    try await Self.withPlayer { _, folder in
      let data = try Data(contentsOf: folder.appendingPathComponent("a.mp4"))
      // mpv reads standard input as the stream it opens, so standard input is replaced with a pipe the file is written to.
      let pipe = Pipe()
      let standardInput = dup(STDIN_FILENO)
      dup2(pipe.fileHandleForReading.fileDescriptor, STDIN_FILENO)
      defer {
        dup2(standardInput, STDIN_FILENO)
        Darwin.close(standardInput)
      }
      let writer = pipe.fileHandleForWriting
      DispatchQueue.global().async {
        try? writer.write(contentsOf: data)
        try? writer.close()
      }
      var status = CommandLineStatus()
      status.isStdin = true
      status.enterMusicMode = true
      #expect(!PlayerCore.playerCores.contains { $0.isInMiniPlayer })
      AppDelegate.shared.openFromCommandLine(status)
      let player = try #require(PlayerCore.playerCores.first { $0.isInMiniPlayer })
      try await Self.waitUntil {
        player.mpv.getString(MPVProperty.path) == "-" && player.info.state == .paused && !player.info.pausedForLoading
      }
      player.switchBackFromMiniPlayer()
      try await Self.close([player])
    }
  }

  @Test("Moving a loop point the A-B loop command has not set asks nothing of mpv")
  func abLoopPointIgnored() async throws {
    try await Self.withPlayer { player, _ in
      #expect(player.info.abLoopStatus == .cleared)
      player.abLoopA = 2
      player.abLoopB = 3
      // mpv answers in the order it is asked, so this answer comes after mpv has set any loop point the moves asked it to.
      _ = await Self.paused(player)
      #expect(player.mpv.getString(MPVOption.PlaybackControl.abLoopA) == "no")
      #expect(player.mpv.getString(MPVOption.PlaybackControl.abLoopB) == "no")
    }
  }

  @Test("Changes of loop-playlist are stored as mpv reported them, giving the playlist loop and then no loop")
  func loopPlaylistChanged() async throws {
    try await Self.withPlayer { player, _ in
      var notices = 0
      player.observe(.iinaLoopStatusChanged) { _ in notices += 1 }
      player.loopOptionChanged(MPVOption.PlaybackControl.loopPlaylist, "inf")
      #expect(player.getLoopMode() == .playlist)
      player.loopOptionChanged(MPVOption.PlaybackControl.loopPlaylist, "no")
      #expect(player.getLoopMode() == .off)
      try await Self.waitUntil { notices == 2 }
    }
  }

  @Test("Changes of the video and secondary subtitle tracks reported once the player is no longer active are ignored")
  func trackChangedWhenInactive() async throws {
    try await Self.withPlayer { player, _ in
      player.mainWindow.close()
      try await Self.waitUntil { player.info.state == .idle }
      var notified = false
      player.observe(.iinaVIDChanged) { _ in notified = true }
      player.observe(.iinaSIDChanged) { _ in notified = true }
      let (vid, secondSid) = (player.info.vid, player.info.secondSid)
      player.vidChanged(7)
      player.secondarySidChanged(7)
      await Self.drainMain()
      #expect(player.info.vid == vid)
      #expect(player.info.secondSid == secondSid)
      #expect(!notified)
    }
  }

  @Test("A secondary subtitle track selected in mpv is stored once mpv reports the change, taking the track id it reported")
  func secondarySidSelected() async throws {
    try await Self.withPlayer { player, folder in
      let subtitles = try Self.writeSubtitles(["b", "c"], in: folder)
      subtitles.forEach { player.loadExternalSubFile($0) }
      try await Self.waitUntil { player.info.subTracks.count == 2 }
      // mpv adds each subtitle file on a thread of its own and selects the file it adds, so either file's track can be the subtitle
      // track. c.srt's is made the subtitle track, so that b.srt's can be the secondary one.
      let primary = try #require(player.info.subTracks.first { $0.externalFilename == subtitles[1].mpvStr })
      player.setTrack(primary.id, forType: .sub)
      try await Self.waitUntil { player.info.sid == primary.id }
      let track = try #require(player.info.subTracks.first { $0.externalFilename == subtitles[0].mpvStr })
      player.setTrack(track.id, forType: .secondSub)
      try await Self.waitUntil { player.info.secondSid == track.id }
      #expect(player.mpv.getInt(MPVOption.Subtitles.secondarySid) == track.id)
    }
  }

  @Test("Reloading the subtitles selects again the reloaded track of the subtitle file selected before")
  func reloadAllSubsReselects() async throws {
    try await Self.withPlayer { player, folder in
      let subtitles = try Self.writeSubtitles(["b", "c"], in: folder)
      subtitles.forEach { player.loadExternalSubFile($0) }
      try await Self.waitUntil { player.info.subTracks.count == 2 }
      let selected = try #require(player.info.subTracks.first { $0.externalFilename == subtitles[0].mpvStr })
      player.setTrack(selected.id, forType: .sub)
      try await Self.waitUntil { player.info.sid == selected.id }
      var stored = false
      player.reloadAllSubs { stored = true }
      try await Self.waitUntil { stored }
      // mpv selects each subtitle track it reloads, c.srt's last, so b.srt's reloaded track is selected only if the player selects
      // it again once the reloads are done.
      let reloaded = try #require(player.info.subTracks.first { $0.externalFilename == subtitles[0].mpvStr })
      try await Self.waitUntil {
        player.mpv.getInt(MPVOption.TrackSelection.sid) == reloaded.id && player.info.sid == reloaded.id
      }
    }
  }

  @Test("A 3D LUT file dragged alone is accepted, judged by its name")
  func dragOfLUT() async throws {
    try await Self.withPlayer { player, folder in
      let lut = folder.appendingPathComponent("look.cube")
      #expect(player.acceptFromPasteboard(FileDrop([lut])) == .copy)
      #expect(player.acceptFromPasteboard(FileDrop([lut]), isPlaylist: true) == .copy)
    }
  }

  @Test("Drags onto the video view and the playlist pane are answered by the player from what is dragged: a folder and a link are accepted, and a subtitle file is refused by the playlist")
  func dragsOntoViews() async throws {
    try await Self.withPlayer { player, folder in
      // Named alone, a folder that does not exist is answered as a folder that does.
      let subfolder = folder.appendingPathComponent("more")
      let link = try #require(URL(string: "https://iina.io/"))
      let videoView = player.mainWindow.videoView
      #expect(videoView.draggingEntered(FileDrop([subfolder])) == .copy)
      #expect(videoView.hasPlayableFiles)
      #expect(videoView.draggingEntered(FileDrop(link: link)) == .copy)
      let pane = SidebarPlaylistPane(player: player)
      let answer = { (drop: FileDrop) in
        pane.tableView(pane.tableView, validateDrop: drop, proposedRow: 0, proposedDropOperation: .above)
      }
      #expect(answer(FileDrop([subfolder])) == .copy)
      #expect(answer(FileDrop(link: link)) == .copy)
      #expect(answer(FileDrop([folder.appendingPathComponent("b.srt")])) == [])
    }
  }

  @Test("The playlist pane of a player no longer active reads nothing when the playlist is reported changed")
  func playlistPaneInactive() async throws {
    try await Self.withPlayer { player, _ in
      let pane = SidebarPlaylistPane(player: player)
      try await Self.waitUntil { pane.tableView.numberOfRows == 3 }
      player.mainWindow.close()
      try await Self.waitUntil { player.info.state == .idle }
      // A held core answers nothing, so a read the pane asked for would be waiting.
      let hold = try MPVCoreHold(player.mpv, limit: Self.holdLimit)
      let waiting = player.mpv.replyCallbacks.count
      player.postNotification(.iinaPlaylistChanged)
      await Self.drainMain()
      #expect(player.mpv.replyCallbacks.count == waiting)
      #expect(pane.tableView.numberOfRows == 3)
      hold.release()
      try await Self.waitUntil { hold.hasLetGo }
    }
  }
}

private final class PlayerPlaybackTestsBundle {}

/// The quality-of-service classes of the threads other than the main thread on which each player posted the playlist-changed
/// notification.
private final class PlaylistChangeRecord: @unchecked Sendable {
  private let lock = NSLock()
  private var classes: [ObjectIdentifier: [qos_class_t]] = [:]

  func add(_ qos: qos_class_t, for player: PlayerCore) {
    lock.withLock { classes[ObjectIdentifier(player), default: []].append(qos) }
  }

  func classes(for player: PlayerCore) -> [qos_class_t] {
    lock.withLock { classes[ObjectIdentifier(player)] ?? [] }
  }
}

/// A drop of files on a view, carrying their paths on a pasteboard of its own as a drag from Finder does.
private final class FileDrop: NSObject, NSDraggingInfo {
  let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("iinaTests-drop-\(UUID().uuidString)"))
  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 0

  init(_ urls: [URL]) {
    super.init()
    draggingPasteboard.declareTypes([.nsFilenames], owner: nil)
    draggingPasteboard.setPropertyList(urls.map(\.path), forType: .nsFilenames)
  }

  /// A drag of a link, carrying it as a URL rather than as a file's path.
  init(link: URL) {
    super.init()
    draggingPasteboard.declareTypes([.nsURL], owner: nil)
    draggingPasteboard.setString(link.absoluteString, forType: .nsURL)
  }

  deinit {
    draggingPasteboard.releaseGlobally()
  }

  var draggingDestinationWindow: NSWindow? { nil }
  var draggingSourceOperationMask: NSDragOperation { .copy }
  var draggingLocation: NSPoint { .zero }
  var draggedImageLocation: NSPoint { .zero }
  var draggedImage: NSImage? { nil }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 0 }
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }

  func slideDraggedImage(to screenPoint: NSPoint) {}

  func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                              searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                              using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}

  func resetSpringLoading() {}
}

/// Serves a file over HTTP on the loopback interface, so that `mpv` reads it as a network stream.
private final class LocalStreamServer {
  private let listener: NWListener
  /// The URL the file is served at.
  let url: URL

  init(serving file: URL) async throws {
    let body = try Data(contentsOf: file)
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    let queue = DispatchQueue(label: "iinaTests-stream")
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      // Whatever range is asked for, the whole file is sent, which mpv reads as a stream it cannot seek in.
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
        let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          listener.stateUpdateHandler = nil
          if let port = listener.port {
            continuation.resume(returning: port)
          } else {
            continuation.resume(throwing: NWError.posix(.EADDRNOTAVAIL))
          }
        case .failed(let error):
          listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
    self.listener = listener
    url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(file.lastPathComponent)")!
  }

  func stop() {
    listener.cancel()
  }
}

/// Dismisses each modal window the app shows while it lives, keeping the text the window showed.
@MainActor
private final class ModalWindowDismisser {
  /// The text of each window dismissed, in the order they were shown.
  private(set) var texts: [[String]] = []
  private let input: String?
  private var answers: [NSApplication.ModalResponse]
  private var timer: Timer?

  /// - Parameters:
  ///   - input: Text entered in the first editable field of each window, which is then answered with its first button, as a user
  ///     typing it and pressing OK would. With `nil` each window is dismissed unanswered.
  ///   - answers: The responses the first windows shown are answered with, in the order they are shown, the windows after them
  ///     being dismissed as `input` says.
  init(entering input: String? = nil, answering answers: [NSApplication.ModalResponse] = []) {
    self.input = input
    self.answers = answers
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss() }
    }
    // While a modal window is shown the main run loop runs only in the modal panel mode.
    RunLoop.main.add(timer, forMode: .modalPanel)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
  }

  private func dismiss() {
    guard let window = NSApp.modalWindow else { return }
    texts.append(Self.texts(of: window))
    if !answers.isEmpty {
      NSApp.stopModal(withCode: answers.removeFirst())
    } else if let input, let field = Self.editableField(in: window.contentView) {
      field.stringValue = input
      NSApp.stopModal(withCode: .alertFirstButtonReturn)
    } else {
      NSApp.stopModal()
    }
  }

  /// The first editable text field in `view` or the views under it.
  private static func editableField(in view: NSView?) -> NSTextField? {
    guard let view else { return nil }
    if let field = view as? NSTextField, field.isEditable {
      return field
    }
    return view.subviews.lazy.compactMap { editableField(in: $0) }.first
  }

  /// The text `element` and the elements under it show, read through accessibility, which also reaches text an alert does not
  /// keep in a text field.
  private static func texts(of element: Any) -> [String] {
    var own: [String?] = []
    var children: [Any] = []
    if let window = element as? NSWindow {
      own = [window.accessibilityTitle(), window.accessibilityLabel()]
      children = window.contentView.map { [$0] } ?? []
    } else if let view = element as? NSView {
      own = [view.accessibilityValue() as? String, view.accessibilityTitle(), view.accessibilityLabel(),
             (view as? NSTextField)?.stringValue]
      children = view.subviews + (view.accessibilityChildren() ?? []).filter { !($0 is NSView) }
    } else if let other = element as? NSAccessibilityElement {
      own = [other.accessibilityValue() as? String, other.accessibilityTitle(), other.accessibilityLabel()]
      children = other.accessibilityChildren() ?? []
    }
    return own.compactMap { $0 }.filter { !$0.isEmpty } + children.flatMap { texts(of: $0) }
  }
}

/// A value replied on another thread, kept on the main thread.
@MainActor
private final class MainReply<Value: Sendable> {
  private(set) var value: Value?

  /// Keep `value` on the main thread, from any thread.
  nonisolated func set(_ value: Value) {
    DispatchQueue.main.async { MainActor.assumeIsolated { self.value = value } }
  }
}

/// Keeps the path of the file each player that posts a notice shows as it posts it, while it lives.
@MainActor
private final class NoticeRecorder {
  /// For each notice posted, in the order posted, the path of the file the player posting it showed.
  private(set) var paths: [String?] = []
  private var observer: NSObjectProtocol?

  init(_ name: Notification.Name) {
    // Without a queue the notice is handled on the thread posting it, while the player is as it was when it posted it.
    observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notice in
      MainActor.assumeIsolated {
        guard let player = notice.object as? PlayerCore else { return }
        self?.paths.append(player.info.currentURL?.path)
      }
    }
  }

  func stop() {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}

/// Runs a block on the main thread each time a player emits an event it listens for.
private final class EventRecorder: EventCallable {
  private let block: @MainActor ([Any]) -> Void

  /// - Parameter block: Run with the data the event is emitted with.
  init(_ block: @escaping @MainActor ([Any]) -> Void) {
    self.block = block
  }

  func call(withArguments args: [Any]) {
    MainActor.assumeIsolated { block(args) }
  }
}

/// A hold on a serial queue: once made, the queue runs nothing else until the hold is released or its limit passes.
private final class QueueHold: @unchecked Sendable {
  private let reached = DispatchSemaphore(value: 0)
  private let released = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var passed = false

  /// Hold `queue`, returning once the queue has reached the hold.
  init(_ queue: DispatchQueue, limit: DispatchTimeInterval) {
    queue.async {
      self.reached.signal()
      if self.released.wait(timeout: .now() + limit) == .timedOut {
        self.lock.lock()
        self.passed = true
        self.lock.unlock()
      }
    }
    reached.wait()
  }

  /// Whether the limit passed before the hold was released, the queue having gone on.
  var limitPassed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return passed
  }

  func release() {
    released.signal()
  }
}

/// Records the LaunchServices requests made, in place of making them.
private final class WorkspaceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var made: [Utility.WorkspaceRequest] = []

  /// The requests recorded, in the order they were made.
  var requests: [Utility.WorkspaceRequest] {
    lock.lock()
    defer { lock.unlock() }
    return made
  }

  /// Record `request`, from any thread.
  /// - Returns: That LaunchServices did what was asked.
  func record(_ request: Utility.WorkspaceRequest) -> Bool {
    lock.lock()
    made.append(request)
    lock.unlock()
    return true
  }
}

/// A navigation to `url`, of which a web view asks its navigation delegate whether to allow it.
private final class NavigationAction: WKNavigationAction {
  private let url: URL

  init(_ url: URL) {
    self.url = url
    super.init()
  }

  override var request: URLRequest { URLRequest(url: url) }
}

private extension PlayerCore {
  /// The state of the player and of its `mpv` core that the tests wait on.
  var testState: String {
    "state \(info.state), pausedForLoading \(info.pausedForLoading), playlist-count \(mpv.getInt(MPVProperty.playlistCount)), "
      + "playlist-pos \(mpv.getInt(MPVProperty.playlistPos)), pause \(mpv.getFlag(MPVOption.PlaybackControl.pause)), "
      + "time-pos \(mpv.getDouble(MPVProperty.timePos)), duration \(info.videoDuration?.second ?? -1)"
  }
}
