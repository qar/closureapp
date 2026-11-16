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
    /// Files downloaded so far and files to download, during a Google Drive import.
    private(set) var downloadProgress: (done: Int, total: Int)?
    /// A Google Drive problem to show the user, until dismissed.
    var driveError: String?
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
    @ObservationIgnored private var importer = FileImporter(libraryRoot: LibraryStore.libraryFolder)
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
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-ClosureFakeFreeSpace"), flag + 1 < arguments.count,
           let bytes = Int64(arguments[flag + 1]) {
            importer.availableSpace = { bytes }
        }
#endif
        // Finish verified imports cut short last time; the next scan picks them up.
        importer.recoverStaging()
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

    /// Copies files or whole folders picked in the Files app into the library. The copy
    /// runs in the background, is verified, and does not start when space is short.
    func importItems(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        let importer = importer
        let report = await Task.detached(priority: .userInitiated) { importer.importCopies(urls) }.value
        if report.audioFiles > 0 || report.companionFiles > 0 { await rescan() }
        importSummary = ImportSummary(source: "Files", report: report)
    }

    /// Moves files from Documents (Finder file sharing, share sheet inbox) into the library.
    func importInbox() async {
        let items = (try? FileManager.default.contentsOfDirectory(at: Self.inboxFolder,
                                                                   includingPropertiesForKeys: nil)) ?? []
        guard !items.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }

        let importer = importer
        let inbox = Self.inboxFolder
        let report = await Task.detached(priority: .userInitiated) { importer.importInbox(inbox) }.value
        // Files Closure does not use stay in Documents. Mention them only when
        // something else happened, so they do not produce a message on every launch.
        guard report.audioFiles > 0 || report.companionFiles > 0 || !report.failed.isEmpty else { return }
        await rescan()
        importSummary = ImportSummary(source: "Finder", report: report)
    }

    // MARK: - Google Drive

    /// Downloads the files and folders picked in the Drive browser, then imports them
    /// through the verified copy path. Folders keep their structure.
    func importFromDrive(_ items: [GoogleDrive.File], client: GoogleDriveClient) async {
        guard !items.isEmpty else { return }
        let downloadRoot = FileManager.default.temporaryDirectory.appendingPathComponent("GoogleDrive-\(UUID().uuidString)", isDirectory: true)
        isImporting = true
        downloadProgress = (0, 0)
        defer {
            try? FileManager.default.removeItem(at: downloadRoot)
            downloadProgress = nil
            isImporting = false
        }
        do {
            var plan: [(file: GoogleDrive.File, destination: URL)] = []
            var sources: [URL] = []
            for item in items {
                if item.isFolder {
                    let folder = downloadRoot.appendingPathComponent(Self.safeName(item.name), isDirectory: true)
                    try await collect(folder: item, into: folder, client: client, plan: &plan)
                    sources.append(folder)
                } else if Self.isImportable(item.name) {
                    let destination = downloadRoot.appendingPathComponent("files", isDirectory: true).appendingPathComponent(Self.safeName(item.name))
                    plan.append((item, destination))
                    sources.append(destination)
                }
            }
            guard !plan.isEmpty else {
                importSummary = ImportSummary(source: "Google Drive", report: FileImporter.Report())
                return
            }

            // The download and the verified copy both need room before the temporary files go.
            let needed = plan.reduce(Int64(0)) { $0 + $1.file.byteCount }
            if let free = importer.availableSpace(), needed * 2 + FileImporter.spaceReserve > free {
                var report = FileImporter.Report()
                report.spaceShortfall = needed * 2 + FileImporter.spaceReserve - free
                importSummary = ImportSummary(source: "Google Drive", report: report)
                return
            }

            let started = Date()
            downloadProgress = (0, plan.count)
            for (index, entry) in plan.enumerated() {
                try FileManager.default.createDirectory(at: entry.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await client.download(entry.file, to: entry.destination)
                downloadProgress = (index + 1, plan.count)
            }
            print(String(format: "[Closure][Drive] downloaded %d file(s), %lld bytes in %.1f s", plan.count, needed, Date().timeIntervalSince(started)))

            let importer = importer
            let existing = sources.filter { FileManager.default.fileExists(atPath: $0.path) }
            let report = await Task.detached(priority: .userInitiated) { importer.importCopies(existing) }.value
            if report.audioFiles > 0 || report.companionFiles > 0 { await rescan() }
            importSummary = ImportSummary(source: "Google Drive", report: report)
        } catch {
            print("[Closure][Drive] import failed: \(error)")
            driveError = error.localizedDescription
        }
    }

    /// Lists a Drive folder recursively and plans where each importable file goes.
    private func collect(folder: GoogleDrive.File, into local: URL, client: GoogleDriveClient,
                         plan: inout [(file: GoogleDrive.File, destination: URL)]) async throws {
        let children = try await client.list(.folder(id: folder.id, name: folder.name))
        for child in children {
            if child.isFolder {
                try await collect(folder: child, into: local.appendingPathComponent(Self.safeName(child.name), isDirectory: true),
                                  client: client, plan: &plan)
            } else if Self.isImportable(child.name) {
                plan.append((child, local.appendingPathComponent(Self.safeName(child.name))))
            }
        }
    }

    private static func isImportable(_ name: String) -> Bool {
        let kind = FileImporter.kind(of: URL(fileURLWithPath: name))
        return kind == .audio || kind == .companion
    }

    /// Drive names may contain "/" or be empty; local file names may not.
    private static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "\u{2215}").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : cleaned
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
