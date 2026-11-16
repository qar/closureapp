import XCTest

/// Tag items mirror what AVFoundation reported for files written by ffmpeg.
final class TagParserTests: XCTestCase {
    private func item(_ id: String, common: String? = nil, _ string: String? = nil, data: [UInt8]? = nil) -> TagItem {
        TagItem(identifier: id, commonKey: common, string: string, number: nil, data: data.map { Data($0) })
    }

    private let expected = ParsedTags(title: "T", artist: "Track Artist", album: "Alb", albumArtist: "Album Artist",
                                      trackNumber: 5, discNumber: 2, year: 2020, composer: "Comp", genre: "Jazz",
                                      isCompilation: true)

    func testFLACVorbisComments() {
        let tags = TagParser.parse([
            item("vorb/TITLE", common: "title", "T"), item("vorb/ARTIST", common: "artist", "Track Artist"),
            item("vorb/ALBUMARTIST", "Album Artist"), item("vorb/ALBUM", common: "albumName", "Alb"),
            item("vorb/DISCNUMBER", "2/3"), item("vorb/TRACKNUMBER", "5/12"), item("vorb/COMPOSER", "Comp"),
            item("vorb/GENRE", "Jazz"), item("vorb/DATE", common: "creationDate", "2020"), item("vorb/COMPILATION", "1"),
        ])
        XCTAssertEqual(tags, expected)
    }

    func testM4AAtoms() {
        let tags = TagParser.parse([
            item("itsk/%A9nam", common: "title", "T"), item("itsk/%A9ART", common: "artist", "Track Artist"),
            item("itsk/aART", "Album Artist"), item("itsk/%A9wrt", "Comp"), item("itsk/%A9alb", common: "albumName", "Alb"),
            item("itsk/%A9day", "2020"), item("itsk/%A9gen", "Jazz"), item("itsk/cpil", "1"),
            item("itsk/trkn", data: [0, 0, 0, 5, 0, 12, 0, 0]), item("itsk/disk", data: [0, 0, 0, 2, 0, 3, 0, 0]),
        ])
        XCTAssertEqual(tags, expected)
    }

    func testMP3Frames() {
        let tags = TagParser.parse([
            item("id3/TIT2", common: "title", "T"), item("id3/TPE1", common: "artist", "Track Artist"),
            item("id3/TPE2", "Album Artist"), item("id3/TALB", common: "albumName", "Alb"), item("id3/TPOS", "2/3"),
            item("id3/TRCK", "5/12"), item("id3/TCOM", common: "creator", "Comp"), item("id3/TCON", common: "type", "Jazz"),
            item("id3/TDRC", "2020"), item("id3/TCMP", "1"),
        ])
        XCTAssertEqual(tags, expected)
    }

    func testBlankValuesAreIgnored() {
        let tags = TagParser.parse([item("vorb/TITLE", common: "title", "  "), item("vorb/TRACKNUMBER", "0")])
        XCTAssertNil(tags.title)
        XCTAssertNil(tags.trackNumber)
    }
}

final class LibraryGroupingTests: XCTestCase {
    private func track(_ path: String, album: String, artist: String = "A", albumArtist: String? = nil,
                       track: Int = 0, disc: Int? = nil, compilation: Bool? = nil) -> Track {
        Track(id: path, title: path, artist: artist, album: album, trackNumber: track, duration: 60, codec: "FLAC",
              sampleRate: 44100, bitDepth: 16, fileSize: 1, modified: .distantPast, year: nil, albumArtist: albumArtist,
              discNumber: disc, composer: nil, genre: nil, isCompilation: compilation)
    }

    func testDiscFoldersWithAlbumArtistFormOneAlbumInDiscOrder() {
        let albums = LibraryGrouping.albums(from: [
            track("Box/CD2/01.flac", album: "Box", albumArtist: "B", track: 1, disc: 2),
            track("Box/CD1/02.flac", album: "Box", albumArtist: "B", track: 2, disc: 1),
            track("Box/CD1/01.flac", album: "Box", albumArtist: "B", track: 1, disc: 1),
        ])
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].tracks.map(\.id), ["Box/CD1/01.flac", "Box/CD1/02.flac", "Box/CD2/01.flac"])
        XCTAssertEqual(albums[0].discs, [1, 2])
    }

    func testDiscFoldersWithoutTagsStillFormOneAlbum() {
        let albums = LibraryGrouping.albums(from: [
            track("Box/CD1/01.flac", album: "Box", disc: 1),
            track("Box/CD2/01.flac", album: "Box", disc: 2),
        ])
        XCTAssertEqual(albums.count, 1)
    }

    func testCompilationStaysTogether() {
        let albums = LibraryGrouping.albums(from: [
            track("Hits/01.flac", album: "Hits", artist: "X", albumArtist: "Various Artists", track: 1),
            track("Hits/02.flac", album: "Hits", artist: "Y", albumArtist: "Various Artists", track: 2),
        ])
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].artist, "Various Artists")

        let untagged = LibraryGrouping.albums(from: [
            track("Mix/01.flac", album: "Mix", artist: "X", track: 1),
            track("Mix/02.flac", album: "Mix", artist: "Y", track: 2),
        ])
        XCTAssertEqual(untagged.count, 1, "same folder and album title without an album artist tag")
        XCTAssertEqual(untagged[0].artist, "Various Artists")
    }

    func testSameTitleByDifferentArtistsStaysApart() {
        let albums = LibraryGrouping.albums(from: [
            track("A/Greatest Hits/01.flac", album: "Greatest Hits", artist: "A", albumArtist: "A"),
            track("B/Greatest Hits/01.flac", album: "Greatest Hits", artist: "B", albumArtist: "B"),
        ])
        XCTAssertEqual(albums.count, 2)
    }

    func testUnknownTrackNumbersSortLast() {
        let albums = LibraryGrouping.albums(from: [
            track("X/b.flac", album: "X"), track("X/a.flac", album: "X", track: 2), track("X/c.flac", album: "X", track: 1),
        ])
        XCTAssertEqual(albums[0].tracks.map(\.id), ["X/c.flac", "X/a.flac", "X/b.flac"])
    }

    func testDiscFolderNames() {
        XCTAssertEqual(LibraryGrouping.discNumber(fromFolderName: "CD1"), 1)
        XCTAssertEqual(LibraryGrouping.discNumber(fromFolderName: "Disc 2"), 2)
        XCTAssertEqual(LibraryGrouping.discNumber(fromFolderName: "disk-3"), 3)
        XCTAssertNil(LibraryGrouping.discNumber(fromFolderName: "CD Collection"))
        XCTAssertNil(LibraryGrouping.discNumber(fromFolderName: "Discography"))
    }
}
