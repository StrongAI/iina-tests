//
//  MPVAsyncRequestTests.swift
//  iinaTests
//
//  Tests for the requests MPVController makes to a real mpv core without waiting for it.
//

import Foundation
import Testing
@testable import IINA

/// Each test makes its own player, so that no test shares an `mpv` core with another. Every player a test makes is kept for the
/// rest of the run, because a started `mpv` core calls back into its `MPVController` for as long as the core exists.
///
/// The tests run on the main thread. A reply `mpv` sends is handled on the thread of the queue for reading `mpv` events, while a
/// request that could not be made is answered on the thread that made it, so the thread a reply arrives on tells the two apart.
@Suite("Requests to mpv that do not wait for it")
@MainActor
struct MPVAsyncRequestTests {

  /// The players the tests made.
  private static var players: [PlayerCore] = []

  /// Fault threshold for a hold on a core that the test releases itself, not an estimate of how long the hold lasts.
  private static let holdLimit: DispatchTimeInterval = .seconds(30)

  /// Fault threshold for a wait on mpv's answers, not an estimate of how long they take.
  private static let faultTimeout: Duration = .seconds(30)

  /// A player whose `mpv` core was never started.
  private static func unstartedPlayer() -> PlayerCore {
    let player = PlayerCore()
    // Like PlayerCore.createPlayerCore, label the player before it logs anything, since its log subsystem is named after it.
    player.label = "iinaTests-mpv-\(players.count)"
    players.append(player)
    return player
  }

  /// A player whose `mpv` core is running.
  private static func startedPlayer() -> PlayerCore {
    let player = unstartedPlayer()
    player.startMPV()
    return player
  }

  /// Ask `mpv` for a flag and wait for the reply.
  /// - Returns: The value replied with, and whether the reply arrived on the main thread.
  private static func flag(_ name: String, of player: PlayerCore) async -> (value: Bool?, onMain: Bool) {
    await withCheckedContinuation { continuation in
      player.mpv.getFlagAsync(name) { continuation.resume(returning: ($0, Thread.isMainThread)) }
    }
  }

  /// Run a command and wait for the reply.
  /// - Returns: The error code replied with, and whether the reply arrived on the main thread.
  private static func run(_ command: MPVCommand, _ args: [String], on player: PlayerCore) async -> (code: Int32, onMain: Bool) {
    await withCheckedContinuation { continuation in
      player.mpv.asyncCommand(command, args: args) { continuation.resume(returning: ($0, Thread.isMainThread)) }
    }
  }

  @Test("A flag asked for before mpv is initialized is answered at once with nil")
  func flagBeforeInitialized() {
    let player = Self.unstartedPlayer()
    var replies: [Bool?] = []
    player.mpv.getFlagAsync(MPVOption.PlaybackControl.pause) { replies.append($0) }
    #expect(replies == [nil])
  }

  @Test("A flag set before mpv is initialized is not sent")
  func setBeforeInitialized() {
    let player = Self.unstartedPlayer()
    player.mpv.setFlagAsync(MPVOption.PlaybackControl.pause, true)
    #expect(player.mpv.mpv == nil)
  }

  @Test("A command run before mpv is initialized is answered at once with an error")
  func commandBeforeInitialized() {
    let player = Self.unstartedPlayer()
    var codes: [Int32] = []
    player.mpv.asyncCommand(.set, args: [MPVOption.PlaybackControl.pause, "yes"]) { codes.append($0) }
    #expect(codes.count == 1)
    #expect(codes.allSatisfy { $0 < 0 })
  }

  @Test("A flag set without waiting is seen by a read asked for after it")
  func setThenRead() async {
    let player = Self.startedPlayer()
    player.mpv.setFlagAsync(MPVOption.PlaybackControl.pause, true)
    let paused = await Self.flag(MPVOption.PlaybackControl.pause, of: player)
    #expect(paused.value == true)
    #expect(!paused.onMain)
    player.mpv.setFlagAsync(MPVOption.PlaybackControl.pause, false)
    let resumed = await Self.flag(MPVOption.PlaybackControl.pause, of: player)
    #expect(resumed.value == false)
    #expect(!resumed.onMain)
  }

  @Test("A property mpv cannot read is answered with nil once mpv has tried")
  func unreadableProperty() async {
    let player = Self.startedPlayer()
    let reply = await Self.flag("iina-tests-no-such-property", of: player)
    #expect(reply.value == nil)
    #expect(!reply.onMain)
  }

  @Test("Properties read as nodes are answered together in the order asked, with nil for one mpv cannot read")
  func nodesRead() async {
    let player = Self.startedPlayer()
    player.mpv.setFlagAsync(MPVOption.PlaybackControl.pause, true)
    let names = [MPVOption.PlaybackControl.pause, "iina-tests-no-such-property", MPVProperty.playlistCount]
    let reply = await withCheckedContinuation { continuation in
      player.mpv.getNodesAsync(names) { values in
        continuation.resume(returning: (count: values.count, paused: values[0] as? Bool, unread: values[1] == nil,
                                        playlistCount: values[2] as? Int64, onMain: Thread.isMainThread))
      }
    }
    #expect(reply.count == 3)
    #expect(reply.paused == true)
    #expect(reply.unread)
    #expect(reply.playlistCount == 0)
    #expect(!reply.onMain)
  }

  @Test("Properties read as nodes before mpv is initialized are answered at once with nil")
  func nodesBeforeInitialized() {
    let player = Self.unstartedPlayer()
    var replies: [(count: Int, allNil: Bool)] = []
    player.mpv.getNodesAsync([MPVOption.PlaybackControl.pause, MPVProperty.playlistCount]) { values in
      replies.append((values.count, values.allSatisfy { $0 == nil }))
    }
    #expect(replies.count == 1)
    #expect(replies.first?.count == 2)
    #expect(replies.first?.allNil == true)
  }

  @Test("No properties read as nodes are answered at once with no values")
  func nodesNone() {
    let player = Self.unstartedPlayer()
    var replies: [Int] = []
    player.mpv.getNodesAsync([]) { replies.append($0.count) }
    #expect(replies == [0])
  }

  @Test("A playlist mpv cannot read leaves the stored playlist as it was")
  func playlistUnread() async {
    let player = Self.unstartedPlayer()
    let stored = MPVPlaylistItem(filename: "/iinaTests/a.mp4", isCurrent: true, isPlaying: false, title: nil)
    player.info.$playlist.withLock { $0 = [stored] }
    let completedOnMain = await withCheckedContinuation { continuation in
      player.getPlaylist { continuation.resume(returning: Thread.isMainThread) }
    }
    #expect(completedOnMain)
    #expect(player.info.playlist.map(\.filename) == ["/iinaTests/a.mp4"])
  }

  @Test("A player that is not active asks mpv nothing to sync the time, and its position sync completes at once")
  func syncInactive() async {
    let player = Self.unstartedPlayer()
    var timeSynced = false
    player.syncTime { timeSynced = true }
    var positionSynced = false
    player.syncPositionIfNeeded { positionSynced = true }
    #expect(positionSynced)
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    #expect(!timeSynced)
  }

  @Test("A command mpv runs is answered with success once it has run")
  func commandSucceeds() async {
    let player = Self.startedPlayer()
    let reply = await Self.run(.set, [MPVOption.PlaybackControl.pause, "yes"], on: player)
    #expect(reply.code >= 0)
    #expect(!reply.onMain)
    #expect(await Self.flag(MPVOption.PlaybackControl.pause, of: player).value == true)
  }

  @Test("A playlist move mpv cannot make is answered with an error once mpv has tried")
  func commandFails() async {
    let player = Self.startedPlayer()
    let reply = await Self.run(.playlistNext, [], on: player)
    #expect(reply.code < 0)
    #expect(!reply.onMain)
  }

  @Test("A command mpv cannot parse is answered at once with an error")
  func commandRefused() async {
    let player = Self.startedPlayer()
    // mpv starts in request order, so the command is asked once a read asked after the start is answered.
    _ = await Self.flag(MPVOption.PlaybackControl.pause, of: player)
    var codes: [Int32] = []
    player.mpv.asyncCommand(.seek, args: ["not-a-time"]) { codes.append($0) }
    #expect(codes.count == 1)
    #expect(codes.allSatisfy { $0 < 0 })
  }

  @Test("A request that waits for mpv returns only once mpv's core has been let go")
  func waitingRequestHeld() throws {
    let player = Self.startedPlayer()
    // Nothing can release the hold while the main thread waits, so the hold lets the core go at its limit.
    let hold = try MPVCoreHold(player.mpv, limit: .milliseconds(200))
    _ = player.mpv.getFlag(MPVOption.PlaybackControl.pause)
    #expect(hold.hasLetGo)
  }

  @Test("A request that does not wait for mpv returns while mpv's core is held, and is handled once it is let go")
  func asyncRequestHeld() async throws {
    let player = Self.startedPlayer()
    let hold = try MPVCoreHold(player.mpv, limit: Self.holdLimit)
    player.mpv.setFlagAsync(MPVOption.PlaybackControl.pause, true)
    #expect(!hold.hasLetGo)
    hold.release()
    #expect(await Self.flag(MPVOption.PlaybackControl.pause, of: player).value == true)
    #expect(hold.hasLetGo)
  }

  /// A property `mpv` holds as an integer, a double or a string, set by the setter for its type.
  enum TypedProperty: String, CaseIterable, Sendable {
    case integer, double, string

    var name: String {
      switch self {
      case .integer: MPVOption.OSD.osdLevel
      case .double: MPVOption.PlaybackControl.speed
      case .string: MPVOption.Window.title
      }
    }

    /// The `index`th value, as a raw command string writes it and as `mpv` answers it when it is described.
    func value(_ index: Int) -> String {
      switch self {
      case .integer: String(index)
      case .double: String(1 + Double(index) / 4)
      case .string: "iinaTests-\(index)"
      }
    }

    /// Set the `index`th value without waiting for `mpv`.
    func set(_ index: Int, on mpv: MPVController) {
      switch self {
      case .integer: mpv.setIntAsync(name, index)
      case .double: mpv.setDoubleAsync(name, 1 + Double(index) / 4)
      case .string: mpv.setStringAsync(name, value(index))
      }
    }
  }

  /// Ask `mpv` for a property as a node and wait for the reply.
  /// - Returns: The value replied with, described, and whether the reply arrived on the main thread.
  private static func described(_ name: String, of player: PlayerCore) async -> (value: String?, onMain: Bool) {
    await withCheckedContinuation { continuation in
      player.mpv.getNodesAsync([name]) { values in
        continuation.resume(returning: (values[0].map { String(describing: $0) }, Thread.isMainThread))
      }
    }
  }

  @Test("Integer, double and string properties set before mpv is initialized are not sent")
  func typedSetBeforeInitialized() {
    let player = Self.unstartedPlayer()
    for property in TypedProperty.allCases {
      property.set(1, on: player.mpv)
    }
    #expect(player.mpv.mpv == nil)
  }

  @Test("An integer, double or string property set without waiting is seen by a read asked for after it",
        arguments: TypedProperty.allCases)
  func typedSetThenRead(_ property: TypedProperty) async {
    let player = Self.startedPlayer()
    for index in 1...2 {
      property.set(index, on: player.mpv)
      let read = await Self.described(property.name, of: player)
      #expect(read.value == property.value(index))
      #expect(!read.onMain)
    }
  }

  @Test("An integer, double or string property set without waiting while raw command strings are in flight returns at once and is set by mpv after them",
        arguments: TypedProperty.allCases)
  func typedSetHeldBehindRawCommands(_ property: TypedProperty) async throws {
    let player = Self.startedPlayer()
    let hold = try MPVCoreHold(player.mpv, limit: Self.holdLimit)
    // The first command string waits for the core on the queue command strings are run on, work queued after it there waits until it
    // is let go, and the second command string waits behind that work, so that mpv is asked the second only once the test lets the
    // queue go. A set sent at once would reach mpv before the second command string and be undone by it.
    var codes: [Int32] = []
    let queueHold = DispatchSemaphore(value: 0)
    player.mpv.command(rawString: "set \(property.name) \(property.value(1))") { codes.append($0) }
    player.mpv.inRequestOrder { queueHold.wait() }
    player.mpv.command(rawString: "set \(property.name) \(property.value(2))") { codes.append($0) }
    property.set(3, on: player.mpv)
    let returnedWhileHeld = !hold.hasLetGo
    hold.release()
    #expect(returnedWhileHeld, "Setting a property while command strings were in flight waited for mpv")
    // The command strings are answered on the main thread, which this test runs on.
    func waitForCodes(_ count: Int) async throws {
      let deadline = ContinuousClock.now + Self.faultTimeout
      while codes.count < count && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    // mpv has handled the first command string, and a set sent at once with it, before the queue is let go.
    try await waitForCodes(1)
    queueHold.signal()
    // A read asked now is held behind the command strings and the set as well, so it is answered after them.
    let read = await Self.described(property.name, of: player)
    #expect(read.value == property.value(3))
    try await waitForCodes(2)
    #expect(codes == [0, 0])
  }
}
