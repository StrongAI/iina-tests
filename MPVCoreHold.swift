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
/// The hold is a second client of the core that asks for a property without waiting. `mpv` handles the request on the thread of
/// its core and queues the reply for the client there, calling the client's wakeup callback on that thread. The callback waits until
/// the hold is released, and the core handles no other request until then. The initializer returns once the core is held, so a
/// request made after it that waits for `mpv` cannot return until the core is let go, while a request that does not wait returns at
/// once.
///
/// `mpv` asks a wakeup callback to return quickly. The hold keeps the core only until it is released, and never longer than its
/// limit. Every event but the replies to requests is turned off for the client, so that nothing but the reply wakes it.
final class MPVCoreHold {

  enum HoldError: Error {
    case clientNotCreated
    case requestRefused(Int32)
    case notHeld
  }

  /// The second client of the core.
  private let client: OpaquePointer
  /// The longest the core is held.
  private let limit: DispatchTimeInterval
  /// Signalled once the core is held.
  private let held = DispatchSemaphore(value: 0)
  /// Signalled to let the core go.
  private let letGo = DispatchSemaphore(value: 0)
  /// Whether the next wakeup of the client holds the core.
  @Atomic private var isArmed = false
  /// Whether the core has been let go, when the hold was released or at its limit.
  ///
  /// This is set on the thread of the core before the core goes on, so while it is `false` after a request returns, the request
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
    self.client = client
    self.limit = limit
    let replies = [MPV_EVENT_GET_PROPERTY_REPLY, MPV_EVENT_SET_PROPERTY_REPLY, MPV_EVENT_COMMAND_REPLY]
    for raw in UInt32(1)...UInt32(31) where !replies.contains(mpv_event_id(rawValue: raw)) {
      // Event numbers mpv does not have are refused, which is harmless.
      _ = mpv_request_event(client, mpv_event_id(rawValue: raw), 0)
    }
    mpv_set_wakeup_callback(client, { context in
      guard let context else { return }
      Unmanaged<MPVCoreHold>.fromOpaque(context).takeUnretainedValue().clientWoken()
    }, Unmanaged.passUnretained(self).toOpaque())
    // An event queued before the other events were turned off has used up the client's wakeup. Taking the events lets the reply
    // wake the client again.
    while mpv_wait_event(client, 0).pointee.event_id != MPV_EVENT_NONE {}
    isArmed = true
    let returnValue = mpv_get_property_async(client, 0, MPVOption.PlaybackControl.pause, MPV_FORMAT_FLAG)
    guard returnValue >= 0 else {
      isArmed = false
      throw HoldError.requestRefused(returnValue)
    }
    // A request that waits for mpv is handled ahead of the requests queued before it, so it could be handled before the core
    // reaches this hold. Requests are made only once the core is held.
    guard held.wait(timeout: .now() + limit) == .success else { throw HoldError.notHeld }
  }

  deinit {
    // Destroying the client waits for the reply to its request, which must not wait for the limit.
    release()
    mpv_destroy(client)
  }

  /// Let the core go.
  func release() {
    letGo.signal()
  }

  /// The client was woken, on the thread that queued it an event.
  private func clientWoken() {
    guard $isArmed.withLock({ isArmed in
      defer { isArmed = false }
      return isArmed
    }) else { return }
    held.signal()
    _ = letGo.wait(timeout: .now() + limit)
    hasLetGo = true
  }
}
