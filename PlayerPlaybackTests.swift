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
      case .chapter, .menuNextChapter, .menuPreviousChapter:
        // The test files have no chapters, so the request changes nothing; only that it does not wait is checked.
        ask = request == .chapter ? { _ = player.playChapter(0) } : request == .menuNextChapter
          ? { handler.menuNextChapter(item()) } : { handler.menuPreviousChapter(item()) }
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

  /// A plugin in `folder` whose script does nothing, in whose context a test evaluates scripts.
  private static func makePlugin(in folder: URL) throws -> JavascriptPlugin {
    let root = folder.appendingPathComponent("iinaTests-plugin")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let info: [String: Any] = ["name": "iinaTests", "author": ["name": "iinaTests"], "identifier": "io.iina.tests",
                               "version": "1.0", "entry": "main.js"]
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
  private var timer: Timer?

  /// - Parameter input: Text entered in the first editable field of each window, which is then answered with its first button, as
  ///     a user typing it and pressing OK would. With `nil` each window is dismissed unanswered.
  init(entering input: String? = nil) {
    self.input = input
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
    if let input, let field = Self.editableField(in: window.contentView) {
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

private extension PlayerCore {
  /// The state of the player and of its `mpv` core that the tests wait on.
  var testState: String {
    "state \(info.state), pausedForLoading \(info.pausedForLoading), playlist-count \(mpv.getInt(MPVProperty.playlistCount)), "
      + "playlist-pos \(mpv.getInt(MPVProperty.playlistPos)), pause \(mpv.getFlag(MPVOption.PlaybackControl.pause)), "
      + "time-pos \(mpv.getDouble(MPVProperty.timePos)), duration \(info.videoDuration?.second ?? -1)"
  }
}
