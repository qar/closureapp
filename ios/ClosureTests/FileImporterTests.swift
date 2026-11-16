import XCTest

final class FileImporterTests: XCTestCase {
    private var root: URL!
    private var inbox: URL!
    private var library: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("FileImporterTests-\(UUID().uuidString)")
        inbox = root.appendingPathComponent("Documents")
        library = root.appendingPathComponent("Music")
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Undo any read-only folders before cleaning up.
        if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        try? fileManager.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func makeFile(_ path: String, in base: URL, bytes: Int = 64) throws -> URL {
        let url = base.appendingPathComponent(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    private func exists(_ path: String, in base: URL) -> Bool {
        fileManager.fileExists(atPath: base.appendingPathComponent(path).path)
    }

    private var importer: FileImporter { FileImporter(libraryRoot: library) }

    // MARK: - Inbox (move)

    func testInboxMovesAudioWithCompanionsAndKeepsUnknownFiles() throws {
        try makeFile("Album/01 One.flac", in: inbox)
        try makeFile("Album/02 Two.flac", in: inbox)
        try makeFile("Album/01 One.lrc", in: inbox)
        try makeFile("Album/cover.jpg", in: inbox)
        try makeFile("Album/Album.cue", in: inbox)
        try makeFile("Album/.DS_Store", in: inbox)
        try makeFile("Album/._01 One.flac", in: inbox)
        try makeFile("Album/extras.zip", in: inbox)

        let report = importer.importInbox(inbox)

        XCTAssertEqual(report.audioFiles, 2)
        XCTAssertEqual(report.companionFiles, 3)
        XCTAssertEqual(report.failed, [])
        XCTAssertEqual(report.leftInPlace, ["Album/extras.zip"])
        for path in ["Album/01 One.flac", "Album/02 Two.flac", "Album/01 One.lrc", "Album/cover.jpg", "Album/Album.cue"] {
            XCTAssertTrue(exists(path, in: library), "\(path) should be in the library")
            XCTAssertFalse(exists(path, in: inbox), "\(path) should have left the inbox")
        }
        XCTAssertFalse(exists("Album/.DS_Store", in: library))
        XCTAssertFalse(exists("Album/.DS_Store", in: inbox), "junk is dropped")
        XCTAssertTrue(exists("Album/extras.zip", in: inbox), "unknown files stay where they are")
    }

    func testInboxRemovesFolderOnlyWhenEmpty() throws {
        try makeFile("Clean Album/01.flac", in: inbox)
        try makeFile("Clean Album/folder.jpg", in: inbox)
        try makeFile("Clean Album/.DS_Store", in: inbox)

        _ = importer.importInbox(inbox)

        XCTAssertFalse(exists("Clean Album", in: inbox), "an emptied folder is removed")
        XCTAssertTrue(exists("Clean Album/01.flac", in: library))
        XCTAssertTrue(exists("Clean Album/folder.jpg", in: library))
    }

    func testFailedMoveNeverDeletesTheSource() throws {
        try makeFile("Album/01.flac", in: inbox)
        try makeFile("Album/02.flac", in: inbox)
        try makeFile("Album/cover.jpg", in: inbox)
        // The destination folder cannot be written, so every transfer fails.
        let blocked = library.appendingPathComponent("Album")
        try fileManager.createDirectory(at: blocked, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocked.path)

        let report = importer.importInbox(inbox)

        XCTAssertEqual(report.audioFiles, 0)
        XCTAssertEqual(Set(report.failed), ["Album/01.flac", "Album/02.flac", "Album/cover.jpg"])
        for path in ["Album/01.flac", "Album/02.flac", "Album/cover.jpg"] {
            XCTAssertTrue(exists(path, in: inbox), "\(path) must stay in the inbox after a failed move")
        }
    }

    func testFolderWithoutAudioIsLeftUntouched() throws {
        try makeFile("Photos/a.jpg", in: inbox)
        try makeFile("Photos/notes.txt", in: inbox)

        let report = importer.importInbox(inbox)

        XCTAssertEqual(report.audioFiles + report.companionFiles, 0)
        XCTAssertEqual(report.leftInPlace, ["Photos"])
        XCTAssertTrue(exists("Photos/a.jpg", in: inbox))
        XCTAssertTrue(exists("Photos/notes.txt", in: inbox))
        XCTAssertFalse(exists("Photos", in: library))
    }

    func testNestedDiscFoldersKeepTheirStructure() throws {
        try makeFile("Box Set/CD1/01.flac", in: inbox)
        try makeFile("Box Set/CD2/01.flac", in: inbox)
        try makeFile("Box Set/CD2/01.lrc", in: inbox)
        try makeFile("Box Set/Scans/booklet.pdf", in: inbox)

        let report = importer.importInbox(inbox)

        XCTAssertEqual(report.audioFiles, 2)
        XCTAssertEqual(report.companionFiles, 2)
        XCTAssertTrue(exists("Box Set/CD1/01.flac", in: library))
        XCTAssertTrue(exists("Box Set/CD2/01.flac", in: library))
        XCTAssertTrue(exists("Box Set/CD2/01.lrc", in: library))
        XCTAssertTrue(exists("Box Set/Scans/booklet.pdf", in: library))
        XCTAssertFalse(exists("Box Set", in: inbox))
    }

    func testShareSheetInboxFilesBecomeLooseImports() throws {
        try makeFile("Inbox/Song.m4a", in: inbox)
        try makeFile("Inbox/Readme.pdf", in: inbox)

        let report = importer.importInbox(inbox)

        XCTAssertEqual(report.audioFiles, 1)
        XCTAssertTrue(exists("Imported/Song.m4a", in: library))
        XCTAssertFalse(exists("Inbox", in: library), "the system Inbox is not an album")
        XCTAssertTrue(exists("Inbox/Readme.pdf", in: inbox), "a lone document stays in the inbox")
    }

    func testLooseCompanionFileStaysInInbox() throws {
        try makeFile("cover.jpg", in: inbox)

        let report = importer.importInbox(inbox)

        XCTAssertEqual(report.leftInPlace, ["cover.jpg"])
        XCTAssertTrue(exists("cover.jpg", in: inbox))
    }

    func testSecondImportOfSameNameDoesNotOverwrite() throws {
        try makeFile("Album/01.flac", in: inbox, bytes: 10)
        _ = importer.importInbox(inbox)
        try makeFile("Album/01.flac", in: inbox, bytes: 20)
        _ = importer.importInbox(inbox)

        XCTAssertTrue(exists("Album/01.flac", in: library))
        XCTAssertTrue(exists("Album/01 2.flac", in: library))
        let first = try Data(contentsOf: library.appendingPathComponent("Album/01.flac"))
        XCTAssertEqual(first.count, 10, "the existing file is not overwritten")
    }

    // MARK: - Files app (copy)

    func testCopyNeverChangesTheSource() throws {
        let source = root.appendingPathComponent("External")
        try makeFile("Live/01.flac", in: source)
        try makeFile("Live/cover.png", in: source)
        try makeFile("Live/.DS_Store", in: source)
        try makeFile("Live/video.mkv", in: source)

        let report = importer.importItem(source.appendingPathComponent("Live"), mode: .copy)

        XCTAssertEqual(report.audioFiles, 1)
        XCTAssertEqual(report.companionFiles, 1)
        XCTAssertEqual(report.leftInPlace, [], "copy mode reports nothing as left behind")
        XCTAssertTrue(exists("Live/01.flac", in: library))
        XCTAssertTrue(exists("Live/cover.png", in: library))
        XCTAssertFalse(exists("Live/.DS_Store", in: library))
        XCTAssertFalse(exists("Live/video.mkv", in: library))
        for path in ["Live/01.flac", "Live/cover.png", "Live/.DS_Store", "Live/video.mkv"] {
            XCTAssertTrue(exists(path, in: source), "\(path) must remain at the source")
        }
    }

    func testKindClassification() {
        XCTAssertEqual(FileImporter.kind(of: URL(fileURLWithPath: "/a/B.FLAC")), .audio)
        XCTAssertEqual(FileImporter.kind(of: URL(fileURLWithPath: "/a/b.lrc")), .companion)
        XCTAssertEqual(FileImporter.kind(of: URL(fileURLWithPath: "/a/._b.flac")), .junk)
        XCTAssertEqual(FileImporter.kind(of: URL(fileURLWithPath: "/a/b.zip")), .other)
    }
}
