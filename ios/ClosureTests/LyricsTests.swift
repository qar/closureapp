import XCTest

final class LyricsTests: XCTestCase {
    func testParsesTimedLinesWithSeveralStampsAndOffset() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse("""
        [ti:Song]
        [ar:Someone]
        [offset:500]
        [00:12.50]First line
        [00:20.00][01:20.00]Chorus
        [00:30.123]<00:30.12>Word <00:31.00>stamps
        [00:40.00]
        """))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["First line", "Chorus", "Word stamps", "Chorus"])
        XCTAssertEqual(lyrics.lines.map { $0.time ?? -1 }, [12.0, 19.5, 29.623, 79.5], accuracy: 0.0001)
    }

    func testCurrentLine() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse("[00:10.00]a\n[00:20.00]b\n[00:30.00]c"))
        XCTAssertNil(lyrics.index(at: 5))
        XCTAssertEqual(lyrics.index(at: 10), 0)
        XCTAssertEqual(lyrics.index(at: 25), 1)
        XCTAssertEqual(lyrics.index(at: 999), 2)
    }

    func testPlainLyricsKeepVerseBreaks() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse("One\nTwo\n\n\n\nThree\n\n"))
        XCTAssertFalse(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["One", "Two", "", "Three"])
        XCTAssertNil(lyrics.index(at: 3))
        XCTAssertNil(Lyrics.parse("\n[ar:x]\n"))
    }

    func testDecodesGBKAndUTF8() throws {
        let text = "[00:01.00]晴天"
        XCTAssertEqual(Lyrics.decode(Data(text.utf8)), text)
        let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = try XCTUnwrap(text.data(using: String.Encoding(rawValue: gbk)))
        XCTAssertEqual(Lyrics.decode(data), text)
        XCTAssertEqual(Lyrics.decode(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)), text)
    }

    func testFindsTheMatchingLrcFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lrc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("01 Song.flac"))
        try Data().write(to: folder.appendingPathComponent("01 Song.LRC"))
        try Data().write(to: folder.appendingPathComponent("02 Other.lrc"))
        XCTAssertEqual(LyricsLoader.sidecar(for: folder.appendingPathComponent("01 Song.flac"))?.lastPathComponent, "01 Song.LRC")
        XCTAssertNil(LyricsLoader.sidecar(for: folder.appendingPathComponent("03 None.flac")))
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
