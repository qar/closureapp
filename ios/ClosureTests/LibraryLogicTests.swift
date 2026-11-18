import XCTest

final class AlbumTitlePartsTests: XCTestCase {
    func testParenthesisedEdition() {
        let parts = AlbumTitleParts("Born To Die (The Paradise Edition)")
        XCTAssertEqual(parts.main, "Born To Die")
        XCTAssertEqual(parts.edition, "The Paradise Edition")
    }

    func testBracketedEdition() {
        XCTAssertEqual(AlbumTitleParts("Abbey Road [Remastered 2019]"),
                       AlbumTitleParts(main: "Abbey Road", edition: "Remastered 2019"))
    }

    func testDashSuffixNeedsAnEditionWord() {
        XCTAssertEqual(AlbumTitleParts("Low Light - Deluxe Edition").edition, "Deluxe Edition")
        XCTAssertEqual(AlbumTitleParts("Born to Die: The Paradise Edition"),
                       AlbumTitleParts(main: "Born to Die", edition: "The Paradise Edition"))
        XCTAssertNil(AlbumTitleParts("Vol. 1: Something Else").edition, "a plain subtitle stays in the title")
        XCTAssertNil(AlbumTitleParts("Hello - Goodbye").edition, "a dash alone does not mark an edition")
    }

    func testTitlesWithoutSuffixStayWhole() {
        XCTAssertEqual(AlbumTitleParts("(What's the Story) Morning Glory?").main, "(What's the Story) Morning Glory?")
        XCTAssertNil(AlbumTitleParts("Low Light").edition)
    }
}

final class FLACPictureTests: XCTestCase {
    private func block(type: UInt8, isLast: Bool, _ body: [UInt8]) -> [UInt8] {
        let n = body.count
        return [(isLast ? 0x80 : 0) | type, UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + body
    }

    private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    private func picture(type: Int, data: [UInt8]) -> [UInt8] {
        let mime = Array("image/jpeg".utf8)
        return be32(type) + be32(mime.count) + mime + be32(0) + be32(500) + be32(500) + be32(24) + be32(0) + be32(data.count) + data
    }

    private func write(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).flac")
        try Data(bytes).write(to: url)
        return url
    }

    func testPrefersFrontCover() throws {
        let streamInfo = block(type: 0, isLast: false, [UInt8](repeating: 0, count: 34))
        let back = block(type: 6, isLast: false, picture(type: 4, data: [9, 9]))
        let front = block(type: 6, isLast: true, picture(type: 3, data: [1, 2, 3]))
        let url = try write(Array("fLaC".utf8) + streamInfo + back + front)
        XCTAssertEqual(FLACPicture.frontCover(in: url), Data([1, 2, 3]))
    }

    func testSkipsLeadingID3Tag() throws {
        // ID3v2.4 header with a 20-byte (syncsafe) tag body.
        let id3 = Array("ID3".utf8) + [4, 0, 0, 0, 0, 0, 20] + [UInt8](repeating: 0, count: 20)
        let streamInfo = block(type: 0, isLast: false, [UInt8](repeating: 0, count: 34))
        let front = block(type: 6, isLast: true, picture(type: 3, data: [7, 7, 7]))
        let url = try write(id3 + Array("fLaC".utf8) + streamInfo + front)
        XCTAssertEqual(FLACPicture.frontCover(in: url), Data([7, 7, 7]))
    }

    func testNoPictureReturnsNil() throws {
        let url = try write(Array("fLaC".utf8) + block(type: 0, isLast: true, [UInt8](repeating: 0, count: 34)))
        XCTAssertNil(FLACPicture.frontCover(in: url))
    }
}
