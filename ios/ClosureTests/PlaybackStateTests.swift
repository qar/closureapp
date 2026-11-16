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

    func testSavesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let saved = state(["Album/01.flac", "Album/02.flac"], index: 1, position: 12)
        saved.save(to: url)
        XCTAssertEqual(PlaybackState.load(from: url), saved)
        XCTAssertNil(PlaybackState.load(from: url.appendingPathExtension("missing")))
    }
}
