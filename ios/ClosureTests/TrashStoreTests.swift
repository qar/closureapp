import XCTest

final class TrashStoreTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var trashRoot: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("TrashStoreTests-\(UUID().uuidString)")
        library = root.appendingPathComponent("Music")
        trashRoot = root.appendingPathComponent("Trash")
        try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    @discardableResult
    private func makeFile(_ path: String, bytes: Int = 16) throws -> URL {
        let url = library.appendingPathComponent(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    private func exists(_ path: String) -> Bool {
        fileManager.fileExists(atPath: library.appendingPathComponent(path).path)
    }

    private func trash(_ path: String, store: TrashStore, now: Date = Date()) throws -> TrashStore.Entry {
        try store.moveToTrash(relativePath: path, title: "T", artist: "A", album: "B", now: now)
    }

    func testDeleteMovesFileAndCompanionsOutOfTheLibrary() throws {
        try makeFile("Album/01 Song.flac")
        try makeFile("Album/01 Song.lrc")
        try makeFile("Album/cover.jpg")
        let store = TrashStore(libraryRoot: library, trashRoot: trashRoot)

        let entry = try trash("Album/01 Song.flac", store: store)

        XCTAssertFalse(exists("Album/01 Song.flac"))
        XCTAssertFalse(exists("Album/01 Song.lrc"), "same-name lyrics go with the track")
        XCTAssertTrue(exists("Album/cover.jpg"), "the album cover stays")
        XCTAssertEqual(entry.companions, ["Album/01 Song.lrc"])
        XCTAssertEqual(store.entries.map(\.id), [entry.id])
    }

    func testRestorePutsFilesBackWhereTheyWere() throws {
        try makeFile("Album/01 Song.flac")
        try makeFile("Album/01 Song.lrc")
        let store = TrashStore(libraryRoot: library, trashRoot: trashRoot)
        let entry = try trash("Album/01 Song.flac", store: store)

        let restored = try store.restore(entry)

        XCTAssertEqual(restored, "Album/01 Song.flac")
        XCTAssertTrue(exists("Album/01 Song.flac"))
        XCTAssertTrue(exists("Album/01 Song.lrc"))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: trashRoot.appendingPathComponent(entry.id.uuidString).path))
    }

    func testRestoreNeverOverwritesAFileThatTookItsPlace() throws {
        try makeFile("Album/01 Song.flac", bytes: 10)
        let store = TrashStore(libraryRoot: library, trashRoot: trashRoot)
        let entry = try trash("Album/01 Song.flac", store: store)
        try makeFile("Album/01 Song.flac", bytes: 20) // re-imported meanwhile

        let restored = try store.restore(entry)

        XCTAssertEqual(restored, "Album/01 Song 2.flac")
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("Album/01 Song.flac")).count, 20)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("Album/01 Song 2.flac")).count, 10)
    }

    func testRestoreRecreatesARemovedFolder() throws {
        try makeFile("Gone/01.flac")
        let store = TrashStore(libraryRoot: library, trashRoot: trashRoot)
        let entry = try trash("Gone/01.flac", store: store)
        try fileManager.removeItem(at: library.appendingPathComponent("Gone"))

        try store.restore(entry)

        XCTAssertTrue(exists("Gone/01.flac"))
    }

    func testPurgeRemovesOnlyExpiredEntries() throws {
        try makeFile("A/old.flac")
        try makeFile("A/new.flac")
        let store = TrashStore(libraryRoot: library, trashRoot: trashRoot)
        let now = Date()
        let old = try trash("A/old.flac", store: store, now: now.addingTimeInterval(-31 * 86_400))
        let new = try trash("A/new.flac", store: store, now: now.addingTimeInterval(-29 * 86_400))

        let purged = store.purgeExpired(now: now)

        XCTAssertEqual(purged.map(\.id), [old.id])
        XCTAssertEqual(store.entries.map(\.id), [new.id])
        XCTAssertFalse(fileManager.fileExists(atPath: trashRoot.appendingPathComponent(old.id.uuidString).path))
        XCTAssertTrue(fileManager.fileExists(atPath: trashRoot.appendingPathComponent(new.id.uuidString).path))
    }

    func testEntriesSurviveRelaunch() throws {
        try makeFile("A/01.flac")
        let entry = try trash("A/01.flac", store: TrashStore(libraryRoot: library, trashRoot: trashRoot))

        let reopened = TrashStore(libraryRoot: library, trashRoot: trashRoot)

        XCTAssertEqual(reopened.entries, [entry])
    }

    func testDeletingAMissingFileThrowsAndChangesNothing() {
        let store = TrashStore(libraryRoot: library, trashRoot: trashRoot)
        XCTAssertThrowsError(try trash("Nope/01.flac", store: store))
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Whole albums

    func testDeletingAnAlbumMovesEveryTrackAndTheLeftoverFolderFiles() throws {
        try makeFile("Album/01 Song.flac")
        try makeFile("Album/01 Song.lrc")
        try makeFile("Album/02 Song.flac")
        try makeFile("Album/cover.jpg")
        try makeFile("Album/booklet.pdf")
        try makeFile("Album/.DS_Store")
        try makeFile("Other/01.flac")
        let store = TrashStore(libraryRoot: library, trashRoot: trashRoot)

        try trash("Album/01 Song.flac", store: store)
        try trash("Album/02 Song.flac", store: store)
        let leftovers = store.moveLeftoversToTrash(folder: "Album", album: "B", artist: "A")

        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(leftovers?.originalPath, "Album/booklet.pdf")
        XCTAssertEqual(leftovers?.companions, ["Album/cover.jpg"])
        XCTAssertEqual(leftovers?.title, "Album files")
        XCTAssertFalse(fileManager.fileExists(atPath: library.appendingPathComponent("Album").path), "the empty album folder goes too")
        XCTAssertTrue(exists("Other/01.flac"))
    }

    func testLeftoversStayWhenAudioRemainsInTheFolder() throws {
        try makeFile("Album/01 Song.flac")
        try makeFile("Album/02 Song.flac")
        try makeFile("Album/cover.jpg")
        let store = TrashStore(libraryRoot: library, trashRoot: trashRoot)

        try trash("Album/01 Song.flac", store: store)
        XCTAssertNil(store.moveLeftoversToTrash(folder: "Album", album: "B", artist: "A"))
        XCTAssertTrue(exists("Album/cover.jpg"))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testRestoringAnAlbumBringsBackTracksCoverAndFolder() throws {
        try makeFile("Album/01 Song.flac")
        try makeFile("Album/cover.jpg")
        let store = TrashStore(libraryRoot: library, trashRoot: trashRoot)
        try trash("Album/01 Song.flac", store: store)
        _ = store.moveLeftoversToTrash(folder: "Album", album: "B", artist: "A")
        XCTAssertFalse(exists("Album/cover.jpg"))

        for entry in store.entries { try store.restore(entry) }

        XCTAssertTrue(exists("Album/01 Song.flac"))
        XCTAssertTrue(exists("Album/cover.jpg"))
        XCTAssertTrue(store.entries.isEmpty)
    }
}
