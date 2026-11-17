import XCTest

final class AlbumOverrideTests: XCTestCase {
    private func track(_ id: String, album: String, artist: String, albumArtist: String? = nil, year: Int? = 2012) -> Track {
        Track(id: id, title: id, artist: artist, album: album, trackNumber: 1, duration: 60, codec: "FLAC",
              sampleRate: 44100, bitDepth: 16, fileSize: 1, modified: Date(timeIntervalSince1970: 0),
              year: year, albumArtist: albumArtist, discNumber: nil, composer: nil, genre: nil, isCompilation: nil)
    }

    func testOverrideChangesWhatIsShownButNotTheIdentity() throws {
        let albums = LibraryGrouping.albums(from: [
            track("Z/01.flac", album: "Zz", artist: "ÃÂ"), track("Z/02.flac", album: "Zz", artist: "Guest"),
            track("B/01.flac", album: "Beta", artist: "Bob"),
        ])
        let key = try XCTUnwrap(albums.first { $0.title == "Zz" }?.id)
        let covers = URL(fileURLWithPath: "/tmp/covers")
        let result = AlbumOverrides.apply([key: AlbumOverride(albumKey: key, title: "Alpha", artist: "Ada", year: 1999, artworkFile: "c.jpg")],
                                          to: albums, coversFolder: covers)

        let edited = try XCTUnwrap(result.first { $0.id == key }, "the album keeps its id")
        XCTAssertEqual(edited.title, "Alpha")
        XCTAssertEqual(edited.artist, "Ada")
        XCTAssertEqual(edited.year, 1999)
        XCTAssertEqual(edited.original, Album.Original(title: "Zz", artist: "Various Artists", year: 2012))
        XCTAssertEqual(edited.artworkOverride, covers.appendingPathComponent("c.jpg"))
        XCTAssertEqual(edited.artworkRequest.override, covers.appendingPathComponent("c.jpg"))
        XCTAssertTrue(edited.tracks.allSatisfy { $0.album == "Alpha" && $0.year == 1999 && $0.albumKey == key })
        XCTAssertEqual(result.map(\.artist), ["Ada", "Bob"], "re-sorted by the new artist")
    }

    func testEmptyOverrideChangesNothing() {
        let albums = LibraryGrouping.albums(from: [track("A/01.flac", album: "A", artist: "X")])
        XCTAssertEqual(AlbumOverrides.apply([albums[0].id: AlbumOverride(albumKey: albums[0].id)], to: albums), albums)
    }

    func testDatabaseKeepsOverridesAndMigratesFromVersionOne() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overrides-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try LibraryDatabase(url: url)
        try database.upsert([track("A/01.flac", album: "A", artist: "X")])
        try database.setOverride(AlbumOverride(albumKey: "k", title: "T", artist: nil, year: 2001, artworkFile: "f.jpg"))
        XCTAssertEqual(try database.allOverrides()["k"], AlbumOverride(albumKey: "k", title: "T", artist: nil, year: 2001, artworkFile: "f.jpg"))

        try database.setOverride(AlbumOverride(albumKey: "k"))
        XCTAssertTrue(try database.allOverrides().isEmpty, "an empty override is deleted")
        XCTAssertEqual(try database.trackCount(), 1, "tracks are untouched")
    }
}
