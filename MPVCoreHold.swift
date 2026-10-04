//
//  MPVCoreHold.swift
//  iinaTests
//
//  Holds the core of a player's mpv, so that a test can tell whether a request returns without waiting for mpv.
//

import Foundation
@testable import IINA

/// Holds the core of a player's `mpv` until it is released.
///
/// The hold is a second client of the core that asks it, without waiting, to load a config file read from one end of a socket pair.
/// `mpv` reads the file on the thread of its core, and the hold keeps the other end open without writing to it, so the read waits
/// there and the core handles no other request until the hold closes its end. The initializer returns once the core is reading, so
/// a request made after it that waits for `mpv` cannot return until the core is let go, while a request that does not wait returns
/// at once.
///
/// The core waits inside a command it is running, as a busy core does, and holds no lock of any client while it waits. A hold
/// that waited inside a client's wakeup callback would keep that client's locks, which every thread that sends `mpv` an event to
/// all clients takes, such as a render that resizes the OSD; no client of the app blocks in its wakeup callback. A FIFO would not
/// do: on macOS, closing its last writer does not wake a reader waiting in `poll`, while closing one end of a socket pair does.
final class MPVCoreHold {

  enum HoldError: Error {
    case clientNotCreated
    case socketNotCreated(Int32)
    case requestRefused(Int32)
    case notHeld
  }

  /// The second client of the core.
  private let client: OpaquePointer
  /// The end of the socket pair the hold keeps; `mpv` reads the other end and closes it when done.
  private let writer: Int32
  /// Whether the core has been let go, when the hold was released or at its limit.
  ///
  /// This is set before the hold closes its end and the core goes on, so while it is `false` after a request returns, the request
  /// returned without `mpv` having handled it.
  @Atomic private(set) var hasLetGo = false

  /// Hold the core of the given `mpv`, returning once it is held.
  ///
  /// This waits on the calling thread for the core to be held, so that nothing else runs on that thread in the meantime. On the main
  /// thread, work that waits for `mpv` would otherwise wait for the held core.
  /// - Parameter limit: Fault threshold for the core to be held, and after which the core is let go, so that a request that waits
  ///     for `mpv` returns and the test fails instead of hanging. It is not an estimate of how long a hold lasts.
  init(_ mpv: MPVController, limit: DispatchTimeInterval) throws {
    guard let client = mpv_create_client(mpv.mpv, "iinaTests-core-hold") else { throw HoldError.clientNotCreated }
    // Nothing reads the client's events, so none are queued for it. The reply to its request is queued whatever it asks for.
    for raw in UInt32(1)...UInt32(31) {
      // Event numbers mpv does not have are refused, which is harmless.
      _ = mpv_request_event(client, mpv_event_id(rawValue: raw), 0)
    }
    var ends: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else {
      let error = errno
      mpv_destroy(client)
      throw HoldError.socketNotCreated(error)
    }
    let reader = ends[0]
    // A comment for mpv to read first. Once it is read the core is inside the command, waiting for the rest of the file.
    let comment: [UInt8] = Array("#\n".utf8)
    let command = ["load-config-file", "fdclose://\(reader)"]
    var arguments: [UnsafePointer<CChar>?] = command.map { UnsafePointer(strdup($0)) }
    defer { arguments.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
    arguments.append(nil)
    guard write(ends[1], comment, comment.count) == comment.count else {
      let error = errno
      ends.forEach { close($0) }
      mpv_destroy(client)
      throw HoldError.socketNotCreated(error)
    }
    let returnValue = mpv_command_async(client, 0, &arguments)
    guard returnValue >= 0 else {
      ends.forEach { close($0) }
      mpv_destroy(client)
      throw HoldError.requestRefused(returnValue)
    }
    // mpv owns the reader from here on and closes it once it has read the end of the file. From here on every property is set,
    // so a hold that throws is let go and cleaned up by deinit.
    self.client = client
    writer = ends[1]
    // A request that waits for mpv is handled ahead of the requests queued before it, so it could be handled before the core
    // reaches this hold. Requests are made only once the core is held.
    let deadline = DispatchTime.now() + limit
    var unread = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
    while poll(&unread, 1, 0) > 0 {
      guard DispatchTime.now() < deadline else { throw HoldError.notHeld }
      usleep(1000)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + limit) { [weak self] in self?.release() }
  }

  deinit {
    // Destroying the client waits for the reply to its request, which must not wait for the limit.
    release()
    mpv_destroy(client)
  }

  /// Let the core go.
  func release() {
    guard $hasLetGo.withLock({ hasLetGo in
      defer { hasLetGo = true }
      return !hasLetGo
    }) else { return }
    // mpv reads the end of the file and finishes the command.
    close(writer)
  }
}
