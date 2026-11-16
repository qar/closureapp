import XCTest

final class LibraryDatabaseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryDatabaseTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func database() throws -> LibraryDatabase {
        try LibraryDatabase(url: folder.appendingPathComponent("library.sqlite"))
    }

    private func track(_ id: String, title: String = "T", album: String = "Album", albumArtist: String? = "A",
                       disc: Int? = 1, size: Int64 = 100, modified: Double = 1_700_000_000) -> Track {
        Track(id: id, title: title, artist: "A", album: album, trackNumber: 3, duration: 201.5, codec: "FLAC",
              sampleRate: 96000, bitDepth: 24, fileSize: size, modified: Date(timeIntervalSince1970: modified),
              year: 2024, albumArtist: albumArtist, discNumber: disc, composer: nil, genre: "Jazz", isCompilation: false)
    }

    func testRoundTripKeepsEveryField() throws {
        let db = try database()
        let original = track("Album/01 é 周.flac")
        try db.upsert([original])
        XCTAssertEqual(try db.allTracks(), [original])
    }

    func testNullableFieldsStayNil() throws {
        let db = try database()
        var original = track("x.flac", albumArtist: nil, disc: nil)
        original.year = nil
        original.genre = nil
        original.isCompilation = nil
        try db.upsert([original])
        XCTAssertEqual(try db.allTracks(), [original])
    }

    func testUpsertReplacesAndDeleteRemoves() throws {
        let db = try database()
        try db.upsert([track("a.flac", title: "Old"), track("b.flac")])
        try db.upsert([track("a.flac", title: "New")])
        try db.delete(ids: ["b.flac"])
        let tracks = try db.allTracks()
        XCTAssertEqual(tracks.map(\.id), ["a.flac"])
        XCTAssertEqual(tracks.first?.title, "New")
    }

    func testDataSurvivesReopening() throws {
        try database().upsert([track("a.flac")])
        XCTAssertEqual(try database().trackCount(), 1)
    }

    func testStamps() throws {
        let db = try database()
        try db.upsert([track("a.flac", size: 42, modified: 123.5)])
        XCTAssertEqual(try db.stamps(), ["a.flac": .init(size: 42, modified: 123.5)])
    }

    func testScanDiff() {
        let disk: [String: LibraryDatabase.Stamp] = ["same": .init(size: 1, modified: 10), "changed": .init(size: 2, modified: 20), "new": .init(size: 3, modified: 30)]
        let rows: [String: LibraryDatabase.Stamp] = ["same": .init(size: 1, modified: 10), "changed": .init(size: 2, modified: 21), "gone": .init(size: 4, modified: 40)]
        XCTAssertEqual(ScanDiff.compute(onDisk: disk, inDatabase: rows),
                       .init(toRead: ["changed", "new"], removed: ["gone"], unchanged: 1))
    }

    /// 50,000 tracks in 5,000 albums: write once, then time load + grouping and the
    /// "nothing changed" scan diff. Prints the numbers; the limits are generous
    /// because simulators and devices differ.
    func testFiftyThousandTracks() throws {
        let db = try database()
        var tracks: [Track] = []
        tracks.reserveCapacity(50_000)
        for album in 0..<5_000 {
            for number in 1...10 {
                var t = track("Artist \(album % 900)/Album \(album)/\(number).flac", title: "Track \(number)",
                              album: "Album \(album)", albumArtist: "Artist \(album % 900)")
                t.trackNumber = number
                tracks.append(t)
            }
        }
        var start = Date()
        try db.upsert(tracks)
        let writeTime = Date().timeIntervalSince(start)

        start = Date()
        let loaded = try db.allTracks()
        let loadTime = Date().timeIntervalSince(start)
        start = Date()
        let albums = LibraryGrouping.albums(from: loaded)
        let groupTime = Date().timeIntervalSince(start)

        start = Date()
        let stamps = try db.stamps()
        let diff = ScanDiff.compute(onDisk: stamps, inDatabase: stamps)
        let diffTime = Date().timeIntervalSince(start)

        print(String(format: "50k tracks: write %.2f s, load %.3f s, group %.3f s, stamps+diff %.3f s", writeTime, loadTime, groupTime, diffTime))
        XCTAssertEqual(loaded.count, 50_000)
        XCTAssertEqual(albums.count, 5_000)
        XCTAssertEqual(diff.unchanged, 50_000)
        XCTAssertLessThan(loadTime + groupTime, 2.0)
        XCTAssertLessThan(diffTime, 1.0)
    }
}
