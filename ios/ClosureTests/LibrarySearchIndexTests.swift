import XCTest

final class LibrarySearchIndexTests: XCTestCase {
    private let documents = [
        LibrarySearchIndex.AlbumDocument(
            id: "jay", title: "十一月的萧邦", artist: "周杰伦",
            tracks: [
                .init(id: "jay/nocturne", title: "夜曲", artist: "周杰伦", composer: "周杰伦"),
            ]),
        LibrarySearchIndex.AlbumDocument(
            id: "jazz", title: "Lemonade", artist: "Beyoncé",
            tracks: [
                .init(id: "jazz/song", title: "Hold Up", artist: "Beyoncé", composer: "Ezra Koenig"),
            ]),
    ]

    func testChineseAndPinyinInitialsFindTheSameAlbumAndTrack() {
        let index = LibrarySearchIndex(documents: documents)
        for query in ["周杰伦", "zjl", "zhoujielun", "ZJL"] {
            let results = index.search(query)
            XCTAssertEqual(results.albums.map(\.id), ["jay"], query)
            XCTAssertEqual(results.tracks.map(\.id), ["jay/nocturne"], query)
        }
    }

    func testSearchesAlbumTitleTrackTitleAndComposer() {
        let index = LibrarySearchIndex(documents: documents)
        XCTAssertEqual(index.search("十一月").albums.map(\.id), ["jay"])
        XCTAssertEqual(index.search("十一月").tracks.map(\.id), ["jay/nocturne"])
        XCTAssertEqual(index.search("夜曲").tracks.map(\.id), ["jay/nocturne"])
        XCTAssertEqual(index.search("koenig").tracks.map(\.id), ["jazz/song"])
        XCTAssertTrue(index.search("koenig").albums.isEmpty)
    }

    func testFoldsAccentsAndIgnoresBlankQuery() {
        let index = LibrarySearchIndex(documents: documents)
        XCTAssertEqual(index.search("beyonce").albums.map(\.id), ["jazz"])
        XCTAssertEqual(index.search("beyonce").tracks.map(\.id), ["jazz/song"])
        XCTAssertEqual(index.search("  "), .init())
    }

    func testSearchFindsUnassignedTrackWithoutInventingAlbum() {
        let index = LibrarySearchIndex(documents: documents,
                                       unassignedTracks: [.init(id: "loose/song", title: "遗失录音", artist: "", composer: nil)])
        let results = index.search("遗失录音")
        XCTAssertTrue(results.albums.isEmpty)
        XCTAssertEqual(results.tracks.map(\.id), ["loose/song"])
        XCTAssertNil(results.tracks[0].albumIndex)
    }
}
