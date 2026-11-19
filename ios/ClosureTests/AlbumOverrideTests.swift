import XCTest

final class AlbumOverrideTests: XCTestCase {
    private func track(_ id: String, album: String, artist: String, albumArtist: String? = nil,
                       year: Int? = 2012, compilation: Bool? = nil) -> Track {
        Track(id: id, title: id, artist: artist, album: album, trackNumber: 1, duration: 60, codec: "FLAC",
              sampleRate: 44100, bitDepth: 16, fileSize: 1, modified: Date(timeIntervalSince1970: 0),
              year: year, albumArtist: albumArtist, discNumber: nil, composer: nil, genre: nil, isCompilation: compilation)
    }

    func testOverrideChangesWhatIsShownButNotTheIdentity() throws {
        let albums = LibraryGrouping.albums(from: [
            track("Z/01.flac", album: "Zz", artist: "ÃÂ", compilation: true),
            track("Z/02.flac", album: "Zz", artist: "Guest", compilation: true),
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

final class SquareThumbnailTests: XCTestCase {
    private func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testTallAndWideImagesBecomeSharpSquares() throws {
        // The short edge sets the size, so a tall screenshot still gives a full 300 px square.
        let tall = try XCTUnwrap(ArtworkStore.squareThumbnail(jpeg(width: 600, height: 1300), side: 300))
        XCTAssertEqual(tall.width, 300)
        XCTAssertEqual(tall.height, 300)
        let wide = try XCTUnwrap(ArtworkStore.squareThumbnail(jpeg(width: 1600, height: 900), side: 500))
        XCTAssertEqual(wide.width, 500)
        XCTAssertEqual(wide.height, 500)
        // Never larger than the image itself.
        let small = try XCTUnwrap(ArtworkStore.squareThumbnail(jpeg(width: 200, height: 400), side: 1500))
        XCTAssertEqual(small.width, 200)
        XCTAssertEqual(small.height, 200)
    }
}
