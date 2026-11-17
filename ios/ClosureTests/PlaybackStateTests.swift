import XCTest

final class PlaybackStateTests: XCTestCase {
    private func track(_ id: String, duration: Double = 200) -> Track {
        Track(id: id, title: id, artist: "A", album: "Album", trackNumber: 1, duration: duration, codec: "FLAC",
              sampleRate: 44100, bitDepth: 16, fileSize: 1, modified: Date(timeIntervalSince1970: 0),
              year: nil, albumArtist: nil, discNumber: nil, composer: nil, genre: nil, isCompilation: nil)
    }

    private func library(_ ids: [String]) -> [String: Track] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, track($0)) })
    }

    private func state(_ ids: [String], index: Int, position: Double) -> PlaybackState {
        PlaybackState(trackIDs: ids, index: index, position: position, context: "Album", repeatMode: 2)
    }

    func testRestoresQueueTrackAndPosition() throws {
        let restored = try XCTUnwrap(state(["a", "b", "c"], index: 1, position: 73.5).restore(from: library(["a", "b", "c"])))
        XCTAssertEqual(restored.tracks.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(restored.index, 1)
        XCTAssertEqual(restored.position, 73.5)
    }

    func testDeletedTracksAreLeftOutAndTheIndexFollows() throws {
        let restored = try XCTUnwrap(state(["a", "b", "c", "d"], index: 2, position: 40).restore(from: library(["b", "c", "d"])))
        XCTAssertEqual(restored.tracks.map(\.id), ["b", "c", "d"])
        XCTAssertEqual(restored.index, 1, "still on c")
        XCTAssertEqual(restored.position, 40)
    }

    func testWhenTheCurrentTrackIsGoneTheNextOneStartsFromZero() throws {
        let restored = try XCTUnwrap(state(["a", "b", "c"], index: 1, position: 40).restore(from: library(["a", "c"])))
        XCTAssertEqual(restored.tracks.map(\.id), ["a", "c"])
        XCTAssertEqual(restored.index, 1)
        XCTAssertEqual(restored.position, 0)
    }

    func testWhenEverythingFromTheCurrentTrackIsGoneTheQueueStartsOver() throws {
        let restored = try XCTUnwrap(state(["a", "b", "c"], index: 2, position: 40).restore(from: library(["a"])))
        XCTAssertEqual(restored.index, 0)
        XCTAssertEqual(restored.position, 0)
        XCTAssertNil(state(["a"], index: 0, position: 1).restore(from: [:]))
    }

    func testAPositionAtTheEndRestartsTheTrack() throws {
        let restored = try XCTUnwrap(state(["a"], index: 0, position: 199.6).restore(from: library(["a"])))
        XCTAssertEqual(restored.position, 0)
    }

    func testStatesSavedBeforeShuffleExistedStillLoad() throws {
        let old = #"{"trackIDs":["a","b"],"index":1,"position":3,"context":"X","repeatMode":1}"#
        let state = try JSONDecoder().decode(PlaybackState.self, from: Data(old.utf8))
        XCTAssertNil(state.shuffled)
        XCTAssertEqual(state.originalTracks(from: library(["a", "b"])).count, 0)
    }

    func testShuffleModeAndTheOriginalOrderRoundTrip() throws {
        var saved = state(["c", "a", "b"], index: 0, position: 5)
        saved.shuffled = true
        saved.originalTrackIDs = ["a", "b", "c", "gone"]
        let decoded = try JSONDecoder().decode(PlaybackState.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.shuffled, true)
        XCTAssertEqual(decoded.originalTracks(from: library(["a", "b", "c"])).map(\.id), ["a", "b", "c"])
    }

    func testSavesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let saved = state(["Album/01.flac", "Album/02.flac"], index: 1, position: 12)
        saved.save(to: url)
        XCTAssertEqual(PlaybackState.load(from: url), saved)
        XCTAssertNil(PlaybackState.load(from: url.appendingPathExtension("missing")))
    }
}

final class StorageSummaryTests: XCTestCase {
    func testMeasuresFoldersAndShares() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Music/Album"), trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: library.appendingPathComponent("01.flac"))
        try Data(count: 50_000).write(to: library.appendingPathComponent("cover.jpg"))
        try Data(count: 10_000).write(to: trash.appendingPathComponent("old.flac"))

        let summary = StorageSummary.measure(library: root.appendingPathComponent("Music"), trash: trash)
        XCTAssertGreaterThanOrEqual(summary.music, 150_000, "covers count too")
        XCTAssertGreaterThanOrEqual(summary.recentlyDeleted, 10_000)
        XCTAssertLessThan(summary.recentlyDeleted, summary.music)
        XCTAssertNotNil(summary.free)

        let shares = try XCTUnwrap(StorageSummary(music: 20, recentlyDeleted: 5, free: 50, capacity: 100).shares)
        XCTAssertEqual(shares.music, 0.20, accuracy: 1e-9, "Recently Deleted counts as other")
        XCTAssertEqual(shares.other, 0.30, accuracy: 1e-9)
        XCTAssertEqual(shares.free, 0.5, accuracy: 1e-9)
    }
}
