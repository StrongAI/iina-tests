//
//  FullLengthTests.swift
//  iinaTests
//

import Foundation
import Testing
@testable import IINA

@Suite("Full length of a file opened from its index")
struct FullLengthTests {

  @Test("The full length replaces a shorter duration")
  func longerReplaces() {
    #expect(FullLength.duration(shown: 0.834, fullLength: 16238.434) == 16238.434)
    #expect(FullLength.duration(shown: nil, fullLength: 60.0) == 60.0)
  }

  @Test("A duration as long as the full length is kept")
  func notLongerKept() {
    #expect(FullLength.duration(shown: 60.0, fullLength: 60.0) == nil)
    #expect(FullLength.duration(shown: 61.0, fullLength: 60.0) == nil)
  }

  @Test("No full length leaves the duration alone")
  func noLength() {
    #expect(FullLength.duration(shown: 0.834, fullLength: -1) == nil)
    #expect(FullLength.duration(shown: 0.834, fullLength: 0) == nil)
  }

  @Test("A seek by percentage lands at that fraction of the full length, short of the end")
  func seekTime() {
    #expect(abs(FullLength.seekTime(percent: 50, fullLength: 16238.4) - 8119.2) < 1e-9)
    #expect(FullLength.seekTime(percent: 0, fullLength: 3720) == 0)
    #expect(FullLength.seekTime(percent: -5, fullLength: 3720) == 0)
    #expect(FullLength.seekTime(percent: 120, fullLength: 3720) < 3720)
  }

  @Test("The remaining time is measured against the full length and scaled by speed when asked")
  func remaining() {
    #expect(FullLength.remaining(fullLength: 3720, position: 720, speed: nil) == 3000)
    #expect(FullLength.remaining(fullLength: 3720, position: 720, speed: 2) == 1500)
    #expect(FullLength.remaining(fullLength: 3720, position: 4000, speed: nil) == 0)
  }

  @Test("A file that does not end in an mfra index has no full length to find")
  func unfragmentedFile() async throws {
    let url = try await TestVideo.write(frames: 30, framesPerSecond: 30)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FFmpegController.fullLength(ofFragmentedFile: url.path) < 0)
  }

  @Test("A missing file has no full length to find")
  func missingFile() {
    #expect(FFmpegController.fullLength(ofFragmentedFile: "/nonexistent/missing.mp4") < 0)
  }
}
