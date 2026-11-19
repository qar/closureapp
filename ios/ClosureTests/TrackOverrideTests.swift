import XCTest

final class TrackOverrideTests: XCTestCase {
    private func track(_ path: String, album: String) -> Track {
        Track(id: path, title: path, artist: "Artist", album: album, trackNumber: 1, duration: 60,
              codec: "FLAC", sampleRate: 44100, bitDepth: 16, fileSize: 4,
              modified: Date(timeIntervalSince1970: 1), year: 2020, albumArtist: nil,
              discNumber: nil, composer: nil, genre: nil, isCompilation: nil)
    }

    func testTrackEditsPersistWithoutChangingTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TrackOverride-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("song.flac")
        let original = Data([1, 2, 3, 4])
        try original.write(to: audio)
        let before = try audio.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(url: databaseURL)
        try database.upsert([track("Album/song.flac", album: "Album")])
        var edit = TrackOverride(trackID: "Album/song.flac")
        edit.title = "Edited Title"
        edit.artist = "Edited Artist"
        edit.genre = "Jazz"
        try database.saveTrackOverrides([edit])

        let reopened = try LibraryDatabase(url: databaseURL)
        let stored = try XCTUnwrap(reopened.allTrackOverrides()[edit.trackID])
        let displayed = stored.apply(to: try XCTUnwrap(reopened.allTracks().first))
        XCTAssertEqual(displayed.title, "Edited Title")
        XCTAssertEqual(displayed.artist, "Edited Artist")
        XCTAssertEqual(displayed.genre, "Jazz")
        XCTAssertEqual(displayed.id, "Album/song.flac")
        XCTAssertEqual(try Data(contentsOf: audio), original)
        XCTAssertEqual(try audio.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)

        try reopened.saveTrackOverrides([TrackOverride(trackID: edit.trackID)])
        XCTAssertTrue(try reopened.allTrackOverrides().isEmpty)
    }

    func testMergeSplitAndRestorePersistAcrossDatabaseReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlbumGrouping-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(url: databaseURL)
        try database.upsert([track("A/01.flac", album: "A"), track("A/02.flac", album: "A"),
                             track("B/01.flac", album: "B")])
        let audio = root.appendingPathComponent("B/01.flac")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data([10, 20, 30, 40])
        try original.write(to: audio)
        func grouped(_ database: LibraryDatabase) throws -> [Album] {
            let edits = try database.allTrackOverrides()
            let tracks = try database.allTracks().map { edits[$0.id]?.apply(to: $0) ?? $0 }
            return AlbumOverrides.apply(try database.allOverrides(), to: LibraryGrouping.albums(from: tracks))
        }
        let loaded = try grouped(database)
        let target = try XCTUnwrap(loaded.first { $0.title == "A" })

        try database.saveTrackOverrides([TrackOverride(trackID: "B/01.flac", groupKey: target.id)])
        let merged = try grouped(database)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].title, "A")
        XCTAssertEqual(Set(merged[0].tracks.map(\.id)), ["A/01.flac", "A/02.flac", "B/01.flac"])
        XCTAssertEqual(merged[0].tracks.first { $0.id == "B/01.flac" }?.album, "A")

        let customKey = "custom:test"
        try database.saveAlbumAssignment(
            [TrackOverride(trackID: "A/02.flac", groupKey: customKey)],
            albumOverride: AlbumOverride(albumKey: customKey, title: "New Album", artist: "New Artist",
                                         year: nil, artworkFile: nil))
        let split = try grouped(database)
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split.first { $0.title == "New Album" }?.tracks.map(\.id), ["A/02.flac"])

        let reloaded = try LibraryDatabase(url: databaseURL)
        let afterRestart = try grouped(reloaded)
        XCTAssertEqual(afterRestart.count, 2)
        XCTAssertEqual(afterRestart.first { $0.title == "New Album" }?.artist, "New Artist")

        try reloaded.saveTrackOverrides([TrackOverride(trackID: "B/01.flac"), TrackOverride(trackID: "A/02.flac")])
        let restored = try grouped(reloaded)
        XCTAssertEqual(Set(restored.map(\.title)), ["A", "B"])
        XCTAssertEqual(restored.first { $0.title == "A" }?.tracks.count, 2)
        XCTAssertEqual(restored.first { $0.title == "B" }?.tracks.map(\.id), ["B/01.flac"])
        XCTAssertEqual(try database.allTracks().map(\.id).sorted(), ["A/01.flac", "A/02.flac", "B/01.flac"])
        XCTAssertEqual(try Data(contentsOf: audio), original)
    }
}
