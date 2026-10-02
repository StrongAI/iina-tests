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

  @Test("A file opened from its mfra index runs from its first packet to the end of its last")
  func indexedFile() throws {
    let path = try #require(Self.fragmentedFile)
    #expect(abs(FFmpegController.fullLength(ofFragmentedFile: path) - 4) < 1e-6)
  }

  @Test("A file that ends in an mfra index but cannot be opened has no full length to find")
  func unopenableFile() throws {
    let path = try #require(Self.fragmentedFile)
    var data = try Data(contentsOf: URL(fileURLWithPath: path))
    // Clear the file type and movie boxes, which come before the first fragment, and keep the index at the end.
    data.replaceSubrange(0..<Self.fragmentedHeaderLength, with: Data(count: Self.fragmentedHeaderLength))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("iinaTests-\(UUID().uuidString).mp4")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FFmpegController.fullLength(ofFragmentedFile: url.path) < 0)
  }

  /// The path of `fragmented.mp4` in the test bundle: a fragmented MP4 that ends in an mfra index, 4 s long, its 40 frames at
  /// 10 frames a second in four fragments. It was written by ffmpeg 9.0.1 with
  /// `ffmpeg -f lavfi -i testsrc2=size=64x48:rate=10:duration=4 -c:v libx264 -bf 0 -g 10 -pix_fmt yuv420p
  /// -movflags +frag_keyframe+empty_moov -an fragmented.mp4`.
  private static var fragmentedFile: String? {
    Bundle(for: FullLengthTestsBundle.self).path(forResource: "fragmented", ofType: "mp4")
  }

  /// The length of the boxes of `fragmented.mp4` before its first fragment, its file type and movie boxes.
  private static let fragmentedHeaderLength = 784
}

/// A class whose bundle is the test bundle.
private final class FullLengthTestsBundle {}
