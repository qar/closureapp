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

    func testDiscFoldersWithoutAlbumArtistStillFormOneAlbum() {
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

        let compilation = LibraryGrouping.albums(from: [
            track("Mix/01.flac", album: "Mix", artist: "X", track: 1, compilation: true),
            track("Mix/02.flac", album: "Mix", artist: "Y", track: 2, compilation: true),
        ])
        XCTAssertEqual(compilation.count, 1)
        XCTAssertEqual(compilation[0].artist, "Various Artists")
    }

    func testFolderDoesNotSupplyAlbumNameOrMembership() {
        let tracks = [track("Downloads/first.flac", album: "", artist: "X"),
                      track("Downloads/second.flac", album: "", artist: "Y")]
        let snapshot = LibraryGrouping.snapshot(from: tracks)
        XCTAssertTrue(snapshot.albums.isEmpty)
        XCTAssertEqual(Set(snapshot.unassignedTracks.map(\.id)), Set(tracks.map(\.id)))
    }

    func testOneTaggedTrackIsAnAlbum() {
        let snapshot = LibraryGrouping.snapshot(from: [track("Imports/song.flac", album: "Release")])
        XCTAssertEqual(snapshot.albums.map(\.title), ["Release"])
        XCTAssertTrue(snapshot.unassignedTracks.isEmpty)
    }

    func testTaggedAlbumsIgnoreFolderAndSeparateArtists() {
        let tracks = [track("Mixed/one.flac", album: "Release", artist: "A"),
                      track("Other/two.flac", album: "Release", artist: "A"),
                      track("Mixed/three.flac", album: "Release", artist: "B")]
        let albums = LibraryGrouping.albums(from: tracks)
        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(Set(albums.first { $0.artist == "A" }?.tracks.map(\.id) ?? []),
                       ["Mixed/one.flac", "Other/two.flac"])
        XCTAssertEqual(albums.first { $0.artist == "B" }?.tracks.map(\.id), ["Mixed/three.flac"])
    }

    func testUserCanAssignUntaggedTrackToAlbum() {
        var untagged = track("Mixed/loose.flac", album: "")
        let tagged = track("Other/release.flac", album: "Release")
        untagged.groupingKeyOverride = tagged.albumKey
        let snapshot = LibraryGrouping.snapshot(from: [untagged, tagged])
        XCTAssertTrue(snapshot.unassignedTracks.isEmpty)
        XCTAssertEqual(snapshot.albums.count, 1)
        XCTAssertEqual(Set(snapshot.albums[0].tracks.map(\.id)), [untagged.id, tagged.id])
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

final class TagTextRepairTests: XCTestCase {
    /// What AVFoundation returns when `bytes` sit in a frame marked ISO-8859-1.
    private func latin1(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { Character(Unicode.Scalar($0)) }.map { String($0) }.joined().unicodeScalars.map { UInt16($0.value) }, as: UTF16.self)
    }

    private func encoded(_ text: String, cfEncoding: CFStringEncodings) -> [UInt8] {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding.rawValue)))
        return [UInt8](text.data(using: encoding)!)
    }

    func testRepairsGBK() {
        let garbled = latin1(encoded("周杰伦 - 晴天", cfEncoding: .GB_18030_2000))
        XCTAssertNotEqual(garbled, "周杰伦 - 晴天")
        XCTAssertEqual(TagTextRepair.repairCJK(garbled, preferTraditional: false), "周杰伦 - 晴天")
    }

    func testRepairsBig5WhenTraditionalIsPreferred() {
        let garbled = latin1(encoded("周杰倫", cfEncoding: .big5_HKSCS_1999))
        XCTAssertEqual(TagTextRepair.repairCJK(garbled, preferTraditional: true), "周杰倫")
        let mixed = latin1(encoded("七里香 (Live)", cfEncoding: .big5_HKSCS_1999))
        XCTAssertEqual(TagTextRepair.repairCJK(mixed, preferTraditional: true), "七里香 (Live)")
    }

    func testLeavesLatinTextAlone() {
        for text in ["Café", "Björk", "Mötley Crüe", "Ålesund", "Sigur Rós", "Beyoncé", "naïve", "Ünal",
                     "Für Elise", "Corazón Niño", "Été", "Señorita", "Dvořák"] {
            XCTAssertEqual(TagTextRepair.repairCJK(text, preferTraditional: false), text)
        }
    }

    func testLeavesCorrectUnicodeAndASCIIAlone() {
        XCTAssertEqual(TagTextRepair.repairCJK("周杰伦", preferTraditional: false), "周杰伦")
        XCTAssertEqual(TagTextRepair.repairCJK("Low Light", preferTraditional: false), "Low Light")
    }

    func testParserRepairsOnlyID3Frames() {
        let garbled = latin1(encoded("晴天", cfEncoding: .GB_18030_2000))
        let id3 = TagParser.parse([TagItem(identifier: "id3/TIT2", commonKey: "title", string: garbled)])
        let vorbis = TagParser.parse([TagItem(identifier: "vorb/TITLE", commonKey: "title", string: garbled)])
        XCTAssertTrue(id3.title == "晴天" || TagTextRepair.prefersTraditionalChinese)
        XCTAssertEqual(vorbis.title, garbled, "Vorbis comments are UTF-8 by spec and are not touched")
    }
}

final class TagTextRepairCoverageTests: XCTestCase {
    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func latin1String(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    /// Random strings of 2–6 characters from GB2312 level 1 (leads 0xB0–0xD7).
    func testGB2312RoundTrip() {
        var random = SeededRandom(state: 42)
        var repaired = 0
        var skipped = 0
        let total = 300
        for _ in 0..<total {
            var bytes: [UInt8] = []
            for _ in 0..<Int.random(in: 2...6, using: &random) {
                bytes += [UInt8.random(in: 0xB0...0xD7, using: &random), UInt8.random(in: 0xA1...0xFE, using: &random)]
            }
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            // Unassigned code points (e.g. 0xD7FA–0xD7FE) decode to private-use characters; skip them.
            guard let original = String(data: Data(bytes), encoding: encoding),
                  original.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) else { skipped += 1; continue }
            if TagTextRepair.repairCJK(latin1String(bytes), preferTraditional: false) == original { repaired += 1 }
        }
        XCTAssertEqual(repaired, total - skipped, "every real GB2312 string is repaired")
    }

    /// Random strings from the frequent Big5 block (leads 0xA4–0xC6).
    func testBig5RoundTrip() {
        var random = SeededRandom(state: 7)
        var repaired = 0
        var total = 0
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
        while total < 300 {
            var bytes: [UInt8] = []
            for _ in 0..<Int.random(in: 2...6, using: &random) {
                let trail = Bool.random(using: &random) ? UInt8.random(in: 0x40...0x7E, using: &random) : UInt8.random(in: 0xA1...0xFE, using: &random)
                bytes += [UInt8.random(in: 0xA4...0xC6, using: &random), trail]
            }
            guard let original = String(data: Data(bytes), encoding: encoding),
                  original.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) else { continue }
            total += 1
            if TagTextRepair.repairCJK(latin1String(bytes), preferTraditional: true) == original { repaired += 1 }
        }
        print("Big5 repaired \(repaired)/\(total)")
        XCTAssertGreaterThanOrEqual(repaired * 100 / total, 90)
    }
}
