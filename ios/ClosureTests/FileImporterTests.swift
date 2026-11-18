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

    // MARK: - Staged, verified copies

    private var staging: URL { root.appendingPathComponent("Staging") }

    private func stagingIsEmpty() -> Bool {
        ((try? fileManager.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty
    }

    func testCopyIsVerifiedThroughStagingAndLeavesNoTrace() throws {
        let source = root.appendingPathComponent("External")
        try makeFile("Album/01.flac", in: source, bytes: 300_000)
        try makeFile("Album/cover.jpg", in: source)

        let report = importer.importItem(source.appendingPathComponent("Album"), mode: .copy)

        XCTAssertEqual(report.audioFiles, 1)
        XCTAssertEqual(report.companionFiles, 1)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("Album/01.flac")),
                       try Data(contentsOf: source.appendingPathComponent("Album/01.flac")))
        XCTAssertTrue(stagingIsEmpty())
    }

    func testCorruptedCopyNeverReachesTheLibrary() throws {
        let source = root.appendingPathComponent("External")
        try makeFile("Album/01.flac", in: source)
        try makeFile("Album/02.flac", in: source)
        var importer = FileImporter(libraryRoot: library)
        importer.afterStaging = { staged in
            if staged.lastPathComponent == "02.flac" { try? Data([0, 0, 0]).write(to: staged) } // simulate a bad write
        }

        let report = importer.importItem(source.appendingPathComponent("Album"), mode: .copy)

        XCTAssertEqual(report.audioFiles, 0)
        XCTAssertEqual(report.failed, ["Album/01.flac", "Album/02.flac"])
        XCTAssertFalse(exists("Album/01.flac", in: library))
        XCTAssertFalse(exists("Album/02.flac", in: library))
        XCTAssertTrue(exists("Album/01.flac", in: source))
        XCTAssertTrue(exists("Album/02.flac", in: source), "the source is never touched")
        XCTAssertTrue(stagingIsEmpty())
    }

    func testFailedInboxVerificationKeepsTheWholeAlbum() throws {
        try makeFile("Album/01.flac", in: inbox)
        try makeFile("Album/02.flac", in: inbox)
        try makeFile("Album/cover.jpg", in: inbox)
        var importer = FileImporter(libraryRoot: library)
        importer.afterStaging = { staged in
            if staged.lastPathComponent == "02.flac" { try? Data([0]).write(to: staged) }
        }

        let report = importer.importInbox(inbox)

        XCTAssertEqual(report.audioFiles + report.companionFiles, 0)
        XCTAssertEqual(Set(report.failed), ["Album/01.flac", "Album/02.flac", "Album/cover.jpg"])
        for path in ["Album/01.flac", "Album/02.flac", "Album/cover.jpg"] {
            XCTAssertTrue(exists(path, in: inbox))
            XCTAssertFalse(exists(path, in: library))
        }
        XCTAssertTrue(stagingIsEmpty())
    }

    func testFailedMergeRollsBackAndKeepsInboxSources() throws {
        try makeFile("Album/existing.flac", in: library, bytes: 12)
        try makeFile("Album/01.flac", in: inbox)
        try makeFile("Album/02.flac", in: inbox)
        var importer = FileImporter(libraryRoot: library)
        importer.beforeCommitMove = { _, destination in
            if destination.lastPathComponent == "02.flac" { throw CocoaError(.fileWriteUnknown) }
        }

        let report = importer.importInbox(inbox)

        XCTAssertEqual(report.audioFiles, 0)
        XCTAssertEqual(report.failed, ["Album/01.flac", "Album/02.flac"])
        XCTAssertTrue(exists("Album/existing.flac", in: library))
        XCTAssertFalse(exists("Album/01.flac", in: library))
        XCTAssertFalse(exists("Album/02.flac", in: library))
        XCTAssertTrue(exists("Album/01.flac", in: inbox))
        XCTAssertTrue(exists("Album/02.flac", in: inbox))

        let recovered = FileImporter(libraryRoot: library).recoverStaging()
        XCTAssertEqual(recovered.audioFiles, 2)
        XCTAssertTrue(exists("Album/01.flac", in: library))
        XCTAssertTrue(exists("Album/02.flac", in: library))
        XCTAssertTrue(stagingIsEmpty())
    }

    func testPartiallyCommittedMergeFinishesAtRecordedDestinations() throws {
        try makeFile("Album/01.flac", in: library, bytes: 10)
        let batch = staging.appendingPathComponent(UUID().uuidString)
        try makeFile("Album/01.flac", in: batch, bytes: 20)
        try makeFile("Album/02.flac", in: batch)
        try JSONSerialization.data(withJSONObject: [
            "files": ["Album/01.flac", "Album/02.flac"],
            "destinations": ["Album/01.flac": "Album/01 2.flac", "Album/02.flac": "Album/02.flac"]
        ]).write(to: batch.appendingPathComponent("manifest.json"))
        try fileManager.moveItem(at: batch.appendingPathComponent("Album/01.flac"),
                                 to: library.appendingPathComponent("Album/01 2.flac"))

        let report = importer.recoverStaging()

        XCTAssertEqual(report.audioFiles, 2)
        XCTAssertTrue(exists("Album/01.flac", in: library))
        XCTAssertTrue(exists("Album/01 2.flac", in: library))
        XCTAssertTrue(exists("Album/02.flac", in: library))
        XCTAssertTrue(stagingIsEmpty())
    }

    func testAtomicAlbumMoveFinishesAfterRestart() throws {
        let batch = staging.appendingPathComponent(UUID().uuidString)
        try makeFile("Album/01.flac", in: batch)
        try makeFile("Album/cover.jpg", in: batch)
        try JSONSerialization.data(withJSONObject: [
            "files": ["Album/01.flac", "Album/cover.jpg"], "atomicRoot": "Album"
        ]).write(to: batch.appendingPathComponent("manifest.json"))
        try fileManager.moveItem(at: batch.appendingPathComponent("Album"),
                                 to: library.appendingPathComponent("Album"))

        let report = importer.recoverStaging()

        XCTAssertEqual(report.audioFiles, 1)
        XCTAssertEqual(report.companionFiles, 1)
        XCTAssertTrue(exists("Album/01.flac", in: library))
        XCTAssertTrue(exists("Album/cover.jpg", in: library))
        XCTAssertTrue(stagingIsEmpty())
    }

    func testNotEnoughSpaceCopiesNothing() throws {
        let source = root.appendingPathComponent("External")
        try makeFile("Album/01.flac", in: source, bytes: 5_000)
        let importer = FileImporter(libraryRoot: library, availableSpace: { FileImporter.spaceReserve + 1_000 })

        let report = importer.importCopies([source.appendingPathComponent("Album")])

        XCTAssertEqual(report.spaceShortfall, 4_000)
        XCTAssertEqual(report.audioFiles, 0)
        XCTAssertFalse(exists("Album", in: library))
    }

    func testVerifiedStagingFinishesOnNextLaunch() throws {
        let batch = staging.appendingPathComponent(UUID().uuidString)
        try makeFile("Album/01.flac", in: batch)
        try makeFile("Album/cover.jpg", in: batch)
        try JSONSerialization.data(withJSONObject: ["files": ["Album/01.flac", "Album/cover.jpg"]])
            .write(to: batch.appendingPathComponent("manifest.json"))

        let report = importer.recoverStaging()

        XCTAssertEqual(report.audioFiles, 1)
        XCTAssertEqual(report.companionFiles, 1)
        XCTAssertTrue(exists("Album/01.flac", in: library))
        XCTAssertTrue(stagingIsEmpty())
    }

    func testLegacyManifestFinishesAfterOneFileWasMoved() throws {
        let batch = staging.appendingPathComponent(UUID().uuidString)
        try makeFile("Album/01.flac", in: batch)
        try makeFile("Album/02.flac", in: batch)
        try JSONSerialization.data(withJSONObject: ["files": ["Album/01.flac", "Album/02.flac"]])
            .write(to: batch.appendingPathComponent("manifest.json"))
        try fileManager.createDirectory(at: library.appendingPathComponent("Album"), withIntermediateDirectories: true)
        try fileManager.moveItem(at: batch.appendingPathComponent("Album/01.flac"),
                                 to: library.appendingPathComponent("Album/01.flac"))

        let report = importer.recoverStaging()

        XCTAssertEqual(report.audioFiles, 1)
        XCTAssertTrue(exists("Album/01.flac", in: library))
        XCTAssertTrue(exists("Album/02.flac", in: library))
        XCTAssertTrue(stagingIsEmpty())
    }

    func testUnverifiedStagingIsDiscarded() throws {
        let batch = staging.appendingPathComponent(UUID().uuidString)
        try makeFile("Album/01.flac", in: batch)

        let report = importer.recoverStaging()

        XCTAssertEqual(report, FileImporter.Report())
        XCTAssertFalse(exists("Album/01.flac", in: library))
        XCTAssertTrue(stagingIsEmpty())
    }
}
