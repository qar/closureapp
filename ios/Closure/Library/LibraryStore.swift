import Foundation
import Observation

/// Prototype library. The app keeps its own copy of every file, in the folder
/// structure it was imported with (see FileImporter):
/// - Files and folders picked in the Files app are copied in. The source is never changed.
/// - Files dropped into the app's Documents folder in Finder are moved in when the app
///   becomes active. Only files that arrived in the library leave Documents.
/// Real library management (database, editing, sync) comes after the prototype.
@MainActor
@Observable
final class LibraryStore {
    private(set) var albums: [Album] = []
    /// False until the database has been read once, so the empty state never flashes.
    private(set) var isLoaded = false
    /// Files read so far and files to read, while a scan reads new or changed files.
    private(set) var scanProgress: (done: Int, total: Int)?
    private(set) var isImporting = false
    /// The result of the last import, until the user dismisses it.
    var importSummary: ImportSummary?
    /// Recently Deleted, newest first.
    private(set) var trashEntries: [TrashStore.Entry] = []

    nonisolated static var libraryFolder: URL { LibraryPaths.musicFolder }

    /// Finder file sharing shows this folder. Files placed here are imported.
    private static let inboxFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    @ObservationIgnored private let catalog: LibraryCatalog = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LibraryCatalog(databaseURL: support.appendingPathComponent("Library/library.sqlite"),
                              legacyIndexURL: support.appendingPathComponent("library.json"))
    }()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private let importer = FileImporter(libraryRoot: LibraryStore.libraryFolder)
    @ObservationIgnored private let trash: TrashStore = {
        var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return TrashStore(libraryRoot: LibraryStore.libraryFolder, trashRoot: folder)
    }()

    init() {
        prepareFolders()
        trash.purgeExpired()
        trashEntries = trash.entries
        let catalog = catalog
        loadTask = Task { [weak self] in
#if DEBUG
            if let count = Self.debugSeedCount { await catalog.seedSynthetic(count: count) }
#endif
            let started = Date()
            let albums = await catalog.load()
            guard let self else { return }
            self.albums = albums
            self.isLoaded = true
            print(String(format: "[Closure] loaded %d tracks in %d albums in %.0f ms",
                         albums.reduce(0) { $0 + $1.tracks.count }, albums.count, Date().timeIntervalSince(started) * 1000))
        }
    }

    // MARK: - Import

    /// Copies files or whole folders picked in the Files app into the library.
    func importItems(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }

        var report = FileImporter.Report()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            report.merge(importer.importItem(url, mode: .copy))
        }
        await rescan()
        importSummary = ImportSummary(source: "Files", report: report)
    }

    /// Moves files from Documents (Finder file sharing, share sheet inbox) into the library.
    func importInbox() async {
        let items = (try? FileManager.default.contentsOfDirectory(at: Self.inboxFolder,
                                                                   includingPropertiesForKeys: nil)) ?? []
        guard !items.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }

        let report = importer.importInbox(Self.inboxFolder)
        // Files Closure does not use stay in Documents. Mention them only when
        // something else happened, so they do not produce a message on every launch.
        guard report.audioFiles > 0 || report.companionFiles > 0 || !report.failed.isEmpty else { return }
        await rescan()
        importSummary = ImportSummary(source: "Finder", report: report)
    }

    // MARK: - Recently Deleted

    /// Moves the track to Recently Deleted. It can be restored until it expires.
    func delete(_ track: Track) async {
        _ = try? trash.moveToTrash(relativePath: track.id, title: track.title, artist: track.artist, album: track.album)
        trashEntries = trash.entries
        await rescan()
    }

    func restore(_ entry: TrashStore.Entry) async {
        _ = try? trash.restore(entry)
        trashEntries = trash.entries
        await rescan()
    }

    func restoreAll() async {
        for entry in trash.entries { _ = try? trash.restore(entry) }
        trashEntries = trash.entries
        await rescan()
    }

    func deletePermanently(_ entry: TrashStore.Entry) {
        trash.deletePermanently(entry)
        trashEntries = trash.entries
    }

    func emptyTrash() {
        for entry in trash.entries { trash.deletePermanently(entry) }
        trashEntries = trash.entries
    }

    private static func isAudio(_ url: URL) -> Bool {
        FileImporter.kind(of: url) == .audio
    }

    // MARK: - Scan

    /// Brings the library in line with the files on disk, away from the main thread.
    /// Albums update about once a second while new files are read. A request that
    /// arrives during a scan runs once more when the scan ends.
    func rescan() async {
        await loadTask?.value
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ClosureNoScan") { return }
#endif
        if isScanning {
            rescanRequested = true
            return
        }
        isScanning = true
        defer { isScanning = false }
        repeat {
            rescanRequested = false
            let started = Date()
            let albums = await catalog.scan(root: Self.libraryFolder) { [weak self] progress in
                await self?.apply(progress)
            }
            self.albums = albums
            print(String(format: "[Closure] scan finished in %.0f ms, %d files read", Date().timeIntervalSince(started) * 1000, scanProgress?.total ?? 0))
            scanProgress = nil
            await ArtworkStore.shared.forgetMisses()
        } while rescanRequested
    }

    private func apply(_ progress: LibraryCatalog.Progress) {
        scanProgress = (progress.done, progress.total)
        if let albums = progress.albums { self.albums = albums }
    }

#if DEBUG
    /// -ClosureSeed <n>: add n synthetic rows before loading (with -ClosureNoScan,
    /// so the scan does not remove them again). For load-time measurements.
    private static var debugSeedCount: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-ClosureSeed"), flag + 1 < arguments.count else { return nil }
        return Int(arguments[flag + 1])
    }
#endif

    // MARK: - Storage

    private func prepareFolders() {
        let fileManager = FileManager.default
        var folder = Self.libraryFolder
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        // Music can be large. Closure will back it up through its own sync, so keep it
        // out of the device backup to iCloud.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
}
