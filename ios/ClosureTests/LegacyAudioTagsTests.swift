import XCTest
import UIKit

final class LegacyAudioTagsTests: XCTestCase {
    private func le32(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }
    }

    private func field(_ bytes: [UInt8], length: Int) -> [UInt8] {
        Array(bytes.prefix(length)) + [UInt8](repeating: 0, count: max(0, length - bytes.count))
    }

    private func id3v1(title: [UInt8], artist: [UInt8], track: UInt8 = 0, genre: UInt8 = 13) -> [UInt8] {
        var bytes = Array("TAG".utf8)
        bytes += field(title, length: 30)
        bytes += field(artist, length: 30)
        bytes += field(Array("Album".utf8), length: 30)
        bytes += Array("1999".utf8)
        bytes += field([], length: 28)
        bytes += [0, track, genre]
        return bytes
    }

    private func apeItem(_ name: String, _ value: [UInt8], flags: Int = 0) -> [UInt8] {
        le32(value.count) + le32(flags) + Array(name.utf8) + [0] + value
    }

    private func apeTag(_ items: [[UInt8]], count: Int? = nil, size: Int? = nil) -> [UInt8] {
        let body = items.flatMap { $0 }
        let footer = Array("APETAGEX".utf8) + le32(2000) + le32(size ?? body.count + 32)
            + le32(count ?? items.count) + le32(0) + [UInt8](repeating: 0, count: 8)
        return body + footer
    }

    private func write(_ bytes: [UInt8]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("sample.mp3")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return url
    }

    func testID3v1ReadsTextTrackYearAndGenre() throws {
        // GBK bytes deliberately stored in a format that only specifies Latin-1.
        let gbkTitle: [UInt8] = [0xD6, 0xDC, 0xBD, 0xDC, 0xC2, 0xD7]
        let url = try write([UInt8](repeating: 0, count: 64)
            + id3v1(title: gbkTitle, artist: Array("Singer".utf8), track: 7))
        let tags = TagParser.parse(LegacyAudioTags.read(from: url).items)
        XCTAssertEqual(tags.title, "周杰伦")
        XCTAssertEqual(tags.artist, "Singer")
        XCTAssertEqual(tags.album, "Album")
        XCTAssertEqual(tags.year, 1999)
        XCTAssertEqual(tags.trackNumber, 7)
        XCTAssertEqual(tags.genre, "Pop")
    }

    func testAPEv2ReadsAllFieldsAndEmbeddedMediaBeforeID3v1() throws {
        let cover = [0xFF, 0xD8, 0xFF, 0xD9] as [UInt8]
        let items = [
            apeItem("Title", Array("APE Title".utf8)),
            apeItem("Artist", Array("APE Artist".utf8)),
            apeItem("Album", Array("APE Album".utf8)),
            apeItem("Album Artist", Array("Album Artist".utf8)),
            apeItem("Track", Array("5/12".utf8)),
            apeItem("Disc", Array("2/3".utf8)),
            apeItem("Year", Array("2020".utf8)),
            apeItem("Genre", Array("Jazz".utf8)),
            apeItem("Composer", Array("Composer".utf8)),
            apeItem("Compilation", Array("1".utf8)),
            apeItem("Lyrics", Array("[00:01.00]Hello".utf8)),
            apeItem("Cover Art (Front)", Array("front.jpg".utf8) + [0] + cover, flags: 2),
        ]
        let url = try write([UInt8](repeating: 0, count: 64) + apeTag(items)
            + id3v1(title: Array("Older Title".utf8), artist: Array("Older Artist".utf8)))
        let parsed = LegacyAudioTags.read(from: url)
        let tags = TagParser.parse(parsed.items)
        XCTAssertEqual(tags.title, "APE Title")
        XCTAssertEqual(tags.artist, "APE Artist")
        XCTAssertEqual(tags.album, "APE Album")
        XCTAssertEqual(tags.albumArtist, "Album Artist")
        XCTAssertEqual(tags.trackNumber, 5)
        XCTAssertEqual(tags.discNumber, 2)
        XCTAssertEqual(tags.year, 2020)
        XCTAssertEqual(tags.genre, "Jazz")
        XCTAssertEqual(tags.composer, "Composer")
        XCTAssertEqual(tags.isCompilation, true)
        XCTAssertEqual(parsed.frontCover, Data(cover))
        XCTAssertEqual(parsed.lyrics, "[00:01.00]Hello")
    }

    func testBrokenOrOversizedAPEv2LeavesID3v1Available() throws {
        let broken = apeTag([apeItem("Title", Array("untrusted".utf8))], size: 17 * 1024 * 1024)
        let url = try write(broken + id3v1(title: Array("Fallback".utf8), artist: []))
        let parsed = LegacyAudioTags.read(from: url)
        XCTAssertEqual(TagParser.parse(parsed.items).title, "Fallback")
        XCTAssertNil(parsed.frontCover)
    }

    func testExtendedID3v1GenreAndAPEv2LyricsLoader() async throws {
        let items = [apeItem("Lyrics", Array("[00:01.00]Hello".utf8))]
        let url = try write(apeTag(items)
            + id3v1(title: Array("Song".utf8), artist: [], genre: 145))
        XCTAssertEqual(TagParser.parse(LegacyAudioTags.read(from: url).items).genre, "Anime")
        let lyrics = await LyricsLoader.loadFromFiles(url)
        XCTAssertEqual(lyrics?.lines.first?.text, "Hello")
    }

    func testAPEv2CoverIsShownByArtworkStore() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let cover = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let url = try write(apeTag([apeItem("Cover Art (Front)", Array("front.jpg".utf8)
            + [0] + Array(cover), flags: 2)]))
        let request = ArtworkStore.Request(key: UUID().uuidString,
                                           directory: url.deletingLastPathComponent(),
                                           sampleTracks: [url], stamp: 0)
        let loaded = await ArtworkStore.shared.image(for: request, pixelSize: 64)
        XCTAssertNotNil(loaded)
    }
}
