import XCTest

/// Duplicates are decided by content (SHA-256) only, never by name.
final class DuplicateTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var source: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("DuplicateTests-\(UUID().uuidString)")
        library = root.appendingPathComponent("Music")
        source = root.appendingPathComponent("Picked")
        try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    @discardableResult
    private func write(_ path: String, in base: URL, seed: UInt8, bytes: Int = 4096) throws -> URL {
        let url = base.appendingPathComponent(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }).write(to: url)
        return url
    }

    private func importer(cache: URL? = nil) -> (FileImporter, ContentIndex) {
        let index = ContentIndex(libraryRoot: library, cacheURL: cache)
        var importer = FileImporter(libraryRoot: library, stagingRoot: root.appendingPathComponent("Staging"), availableSpace: { nil })
        importer.contentIndex = index
        return (importer, index)
    }

    private func exists(_ path: String) -> Bool { fileManager.fileExists(atPath: library.appendingPathComponent(path).path) }

    // MARK: - Content, not names

    func testSameContentUnderAnotherNameIsADuplicate() throws {
        try write("Born to Die/01 Born to Die.flac", in: library, seed: 1)
        try write("Renamed/track-a.flac", in: source, seed: 1)
        try write("Renamed/track-b.flac", in: source, seed: 2)

        let report = importer().0.importCopies([source.appendingPathComponent("Renamed")])

        XCTAssertEqual(report.duplicates, ["Renamed/track-a.flac"])
        XCTAssertEqual(report.audioFiles, 1)
        XCTAssertFalse(exists("Renamed/track-a.flac"))
        XCTAssertTrue(exists("Renamed/track-b.flac"))
    }

    func testSameNameWithOtherContentIsNotADuplicate() throws {
        try write("Album/01.flac", in: library, seed: 1)
        try write("Album/01.flac", in: source, seed: 9) // same name and size, other bytes

        let report = importer().0.importCopies([source.appendingPathComponent("Album")])

        XCTAssertEqual(report.duplicates, [])
        XCTAssertEqual(report.audioFiles, 1)
        XCTAssertTrue(exists("Album/01 2.flac"))
    }

    func testAFolderThatIsAllDuplicatesIsSkippedWithItsCover() throws {
        try write("Album/01.flac", in: library, seed: 1)
        try write("Album/02.flac", in: library, seed: 2)
        try write("Album/cover.jpg", in: library, seed: 3, bytes: 100)
        try write("Album/01.flac", in: source, seed: 1)
        try write("Album/02.flac", in: source, seed: 2)
        try write("Album/cover.jpg", in: source, seed: 3, bytes: 100)

        let report = importer().0.importCopies([source.appendingPathComponent("Album")])

        XCTAssertEqual(report.duplicates.sorted(), ["Album/01.flac", "Album/02.flac"])
        XCTAssertEqual(report.audioFiles + report.companionFiles, 0)
        XCTAssertFalse(exists("Album/cover 2.jpg"))
        XCTAssertTrue(fileManager.fileExists(atPath: source.appendingPathComponent("Album/01.flac").path), "a copy import never touches the source")
    }

    func testTheSecondOfTwoIdenticalPicksIsSkipped() throws {
        try write("a.flac", in: source, seed: 5)
        try write("b.flac", in: source, seed: 5)

        let report = importer().0.importCopies([source.appendingPathComponent("a.flac"), source.appendingPathComponent("b.flac")])

        XCTAssertEqual(report.audioFiles, 1)
        XCTAssertEqual(report.duplicates, ["b.flac"])
    }

    func testInboxDuplicatesLeaveDocuments() throws {
        let inbox = root.appendingPathComponent("Documents")
        try write("Imported/x.flac", in: library, seed: 4)
        try write("copy.flac", in: inbox, seed: 4)

        let report = importer().0.importInbox(inbox)

        XCTAssertEqual(report.duplicates, ["copy.flac"])
        XCTAssertFalse(fileManager.fileExists(atPath: inbox.appendingPathComponent("copy.flac").path))
        XCTAssertFalse(exists("Imported/copy.flac"))
    }

    // MARK: - Index

    func testDuplicateGroupsAndHashCache() throws {
        try write("A/01.flac", in: library, seed: 1)
        try write("A/01 2.flac", in: library, seed: 1)
        try write("Imported/01.flac", in: library, seed: 1)
        try write("B/01.flac", in: library, seed: 2) // same size, other content
        try write("A/cover.jpg", in: library, seed: 7, bytes: 10)
        try write("B/cover.jpg", in: library, seed: 7, bytes: 10) // shared art is not a duplicate track

        let cache = root.appendingPathComponent("hashes.json")
        let index = ContentIndex(libraryRoot: library, cacheURL: cache)
        index.refresh()
        XCTAssertEqual(index.duplicateGroups(), [["A/01 2.flac", "A/01.flac", "Imported/01.flac"]])
        index.save()

        // A fresh index reads the hashes from the cache.
        let again = ContentIndex(libraryRoot: library, cacheURL: cache)
        again.refresh()
        XCTAssertEqual(again.duplicateGroups().count, 1)
        let sha = try XCTUnwrap(ContentIndex.sha256(of: library.appendingPathComponent("A/01.flac")))
        XCTAssertEqual(again.libraryFiles(size: 4096, sha256: sha.uppercased()).count, 3, "Drive hex may differ in case")
    }

    func testAChangedFileIsHashedAgain() throws {
        let file = try write("A/01.flac", in: library, seed: 1)
        try write("B/01.flac", in: library, seed: 1)
        let cache = root.appendingPathComponent("hashes.json")
        let index = ContentIndex(libraryRoot: library, cacheURL: cache)
        index.refresh()
        XCTAssertEqual(index.duplicateGroups().count, 1)

        try write("A/01.flac", in: library, seed: 8)
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        XCTAssertEqual(index.duplicateGroups().count, 0)
    }

    func testDefaultKeepPrefersTheAlbumFolderAndTheOriginalName() {
        XCTAssertEqual(DuplicatesViewKeep.pick(["Born/01 x 2.flac", "Born/01 x.flac", "Imported/01 x.flac"]), "Born/01 x.flac")
        XCTAssertEqual(DuplicatesViewKeep.pick(["Imported/a.flac", "Zed/long folder name/a.flac"]), "Zed/long folder name/a.flac")
    }

    // MARK: - Drive jobs

    func testImporterDuplicatesMarkDriveItems() {
        var job = DownloadJob(items: [
            DownloadItem(id: "1", name: "01.flac", size: 4, relativePath: "Album/01.flac", state: .imported),
            DownloadItem(id: "2", name: "cover.jpg", size: 4, relativePath: "Album/cover.jpg", state: .imported),
            DownloadItem(id: "3", name: "x.flac", size: 4, relativePath: "files/x.flac", state: .imported),
            DownloadItem(id: "4", name: "01.flac", size: 4, relativePath: "Other/01.flac", state: .imported),
            DownloadItem(id: "5", name: "02.flac", size: 4, relativePath: "Other/02.flac", state: .imported),
        ])
        job.markDuplicates(["Album/01.flac", "x.flac", "Other/01.flac"])
        XCTAssertEqual(job.items.map(\.state), [.alreadyInLibrary, .alreadyInLibrary, .alreadyInLibrary, .alreadyInLibrary, .imported])
        XCTAssertEqual(job.alreadyInLibraryCount, 4)
    }
}
