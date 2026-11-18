import Foundation
import SwiftUI
import ImageIO
import UIKit
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
    private(set) var albums: [Album] = [] {
        didSet {
            tracksByID = Dictionary(albums.flatMap(\.tracks).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            searchRevision &+= 1
        }
    }
    private(set) var searchRevision = 0
    /// Every track by its path, for playlists.
    @ObservationIgnored private(set) var tracksByID: [String: Track] = [:]
    /// Favorites first, then the user's playlists in the order they were made.
    private(set) var playlists: [Playlist] = []
    /// False until the database has been read once, so the empty state never flashes.
    private(set) var isLoaded = false
    /// Files read so far and files to read, while a scan reads new or changed files.
    private(set) var scanProgress: (done: Int, total: Int)?
    private(set) var isImporting = false
    /// A Google Drive problem to show the user, until dismissed.
    var driveError: String?
    /// The result of the last import, until the user dismisses it.
    var importSummary: ImportSummary?
    /// Recently Deleted, newest first.
    private(set) var trashEntries: [TrashStore.Entry] = []
    /// Library audio files with identical content (SHA-256), one group per content.
    private(set) var duplicateGroups: [[String]] = []
    /// Tracks whose files went missing without being deleted, until the user clears them.
    private(set) var missingFiles: [MissingFile] = []
    /// Problems found by the last scan, to tell the user once.
    var fileNotice: FileNotice?
    /// Tracks the engine cannot read (unsupported or damaged files).
    var unreadableTracks: [Track] { albums.flatMap(\.tracks).filter(\.isUnreadable) }
    /// Space used by the library and Recently Deleted, and free space. Measured after
    /// each scan and after Recently Deleted changes.
    private(set) var storage: StorageSummary?

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
    @ObservationIgnored private let contentIndex = ContentIndex(
        libraryRoot: LibraryStore.libraryFolder,
        cacheURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library/content-hashes.json"))
    @ObservationIgnored private var duplicateTask: Task<Void, Never>?
    nonisolated static var trashFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trash", isDirectory: true)
    }
    @ObservationIgnored private let trash: TrashStore = {
        var folder = LibraryStore.trashFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return TrashStore(libraryRoot: LibraryStore.libraryFolder, trashRoot: folder)
    }()

    struct FileNotice: Identifiable, Equatable {
        let id = UUID()
        var unreadable: Int
        var missing: Int
    }

    private static var missingListURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library/missing-files.json")
    }

    init() {
        prepareFolders()
        importer.contentIndex = contentIndex
        missingFiles = FileProblems.load(from: Self.missingListURL)
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-ClosureFakeFreeSpace"), flag + 1 < arguments.count,
           let bytes = Int64(arguments[flag + 1]) {
            importer.availableSpace = { bytes }
        }
#endif
        // The first Drive import downloaded into tmp/GoogleDrive-*; remove what it left.
        let temporary = FileManager.default.temporaryDirectory
        for item in (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix("GoogleDrive-") {
            try? FileManager.default.removeItem(at: item)
        }
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
            self.playlists = await catalog.playlists()
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
        guard report.audioFiles > 0 || report.companionFiles > 0 || !report.failed.isEmpty || !report.duplicates.isEmpty else { return }
        await rescan()
        importSummary = ImportSummary(source: "Finder", report: report)
    }

    // MARK: - Google Drive

    /// Free space for imports (overridable in debug builds).
    func availableSpace() -> Int64? { importer.availableSpace() }

    /// Which of these Drive files (id, size, SHA-256) the library already has.
    func filesAlreadyInLibrary(_ files: [(id: String, size: Int64, sha256: String)]) async -> Set<String> {
        let index = contentIndex
        return await Task.detached(priority: .userInitiated) {
            index.refresh()
            defer { index.save() }
            return Set(files.filter { !index.libraryFiles(size: $0.size, sha256: $0.sha256).isEmpty }.map(\.id))
        }.value
    }

    /// Imports files the Drive download manager finished, through the verified copy
    /// path. Folders keep their structure.
    func importDownloaded(_ sources: [URL]) async -> FileImporter.Report {
        isImporting = true
        defer { isImporting = false }
        let importer = importer
        let report = await Task.detached(priority: .userInitiated) { importer.importCopies(sources) }.value
        if report.audioFiles > 0 || report.companionFiles > 0 { await rescan() }
        return report
    }

    // MARK: - Recently Deleted

    /// Moves the track to Recently Deleted. It can be restored until it expires.
    func delete(_ track: Track) async {
        _ = try? trash.moveToTrash(relativePath: track.id, title: track.title, artist: track.artist, album: track.album)
        trashEntries = trash.entries
        await rescan()
    }

    /// Moves every track of the album to Recently Deleted (one entry each, so any
    /// of them can come back alone), then the cover and other files left in its
    /// folder.
    func deleteAlbum(_ album: Album) async {
        for track in album.tracks {
            _ = try? trash.moveToTrash(relativePath: track.id, title: track.title, artist: track.artist, album: track.album)
        }
        let folders = Set(album.tracks.map { ($0.id as NSString).deletingLastPathComponent })
        for folder in folders.sorted(by: { $0.count > $1.count }) where !folder.isEmpty {
            trash.moveLeftoversToTrash(folder: folder, album: album.title, artist: album.artist)
        }
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
        measureStorage()
    }

    /// Moves files to Recently Deleted (extra copies, unreadable files). `paths` are
    /// library-relative.
    func moveFilesToTrash(_ paths: [String]) async {
        let tracks = Dictionary(albums.flatMap(\.tracks).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for path in paths {
            let track = tracks[path]
            _ = try? trash.moveToTrash(relativePath: path, title: track?.title ?? (path as NSString).lastPathComponent,
                                       artist: track?.artist ?? "", album: track?.album ?? "")
        }
        trashEntries = trash.entries
        duplicateGroups = duplicateGroups.compactMap { group in
            let left = group.filter { !paths.contains($0) }
            return left.count > 1 ? left : nil
        }
        await rescan()
    }

    func emptyTrash() {
        for entry in trash.entries { trash.deletePermanently(entry) }
        trashEntries = trash.entries
        measureStorage()
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
            await noteFileProblems()
            scanProgress = nil
            await ArtworkStore.shared.forgetMisses()
        } while rescanRequested
        findDuplicates()
        measureStorage()
    }

    /// Records files that went missing (not deleted by the user) and tells the user
    /// about problems this scan found for the first time.
    private func noteFileProblems() async {
        let removed = await catalog.lastRemoved
        let unreadable = await catalog.lastNewlyUnreadable
        let trashed = Set(trash.entries.map(\.originalPath))
        let missing = FileProblems.missing(removed: removed, trashedPaths: trashed)
        if !missing.isEmpty {
            missingFiles = FileProblems.merge(missing, into: missingFiles)
            FileProblems.save(missingFiles, to: Self.missingListURL)
        }
        if !missing.isEmpty || !unreadable.isEmpty {
            print("[Closure] file problems: \(unreadable.count) unreadable, \(missing.count) missing")
            fileNotice = FileNotice(unreadable: unreadable.count, missing: missing.count)
        }
    }

    func clearMissingFiles() {
        missingFiles = []
        FileProblems.save([], to: Self.missingListURL)
    }

    // MARK: - Playlists

    func playlist(_ id: String) -> Playlist? { playlists.first { $0.id == id } }

    var favorites: Playlist? { playlist(Playlist.favoritesID) }

    func isFavorite(_ track: Track) -> Bool { favorites?.trackIDs.contains(track.id) ?? false }

    @discardableResult
    func createPlaylist(named name: String, with tracks: [Track] = []) async -> Playlist {
        let playlist = Playlist(id: UUID().uuidString, name: Self.cleanName(name), trackIDs: Self.unique(tracks.map(\.id)))
        playlists = await catalog.savePlaylist(playlist)
        return playlist
    }

    func renamePlaylist(_ id: String, to name: String) async {
        guard var playlist = playlist(id), !playlist.isFavorites else { return }
        playlist.name = Self.cleanName(name)
        playlists = await catalog.savePlaylist(playlist)
    }

    func deletePlaylist(_ id: String) async {
        playlists = await catalog.deletePlaylist(id: id)
    }

    /// Adds tracks at the end, skipping ones the playlist already has. Returns how many were added.
    @discardableResult
    func add(_ tracks: [Track], to id: String) async -> Int {
        guard var playlist = playlist(id) else { return 0 }
        let new = Self.unique(tracks.map(\.id)).filter { !playlist.trackIDs.contains($0) }
        guard !new.isEmpty else { return 0 }
        playlist.trackIDs += new
        playlists = await catalog.savePlaylist(playlist)
        return new.count
    }

    func toggleFavorite(_ track: Track) async {
        guard var favorites else { return }
        if let index = favorites.trackIDs.firstIndex(of: track.id) {
            favorites.trackIDs.remove(at: index)
        } else {
            favorites.trackIDs.append(track.id)
        }
        playlists = await catalog.savePlaylist(favorites)
    }

    /// Removes tracks at positions of the visible list (tracks still in the library).
    func removeFromPlaylist(_ id: String, at offsets: IndexSet) async {
        guard var playlist = playlist(id) else { return }
        let visible = playlist.tracks(in: tracksByID).map(\.id)
        let removed = Set(offsets.compactMap { visible.indices.contains($0) ? visible[$0] : nil })
        playlist.trackIDs.removeAll { removed.contains($0) }
        playlists = await catalog.savePlaylist(playlist)
    }

    /// Reorders the visible list; tracks now in Recently Deleted keep their place after it.
    func movePlaylistItems(_ id: String, from source: IndexSet, to destination: Int) async {
        guard var playlist = playlist(id) else { return }
        var visible = playlist.tracks(in: tracksByID).map(\.id)
        visible.move(fromOffsets: source, toOffset: destination)
        let hidden = playlist.trackIDs.filter { tracksByID[$0] == nil }
        playlist.trackIDs = visible + hidden
        playlists = await catalog.savePlaylist(playlist)
    }

    private static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Playlist" : trimmed
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - Album edits

    /// The album's saved edits (empty when it has none).
    func override(for albumID: String) async -> AlbumOverride {
        await catalog.overrides[albumID] ?? AlbumOverride(albumKey: albumID)
    }

    /// Saves the user's album edits. `cover` is image data to use as the cover; nil
    /// keeps the current one, unless `removeCover` is set. Files are never changed.
    func saveAlbumEdit(_ albumID: String, title: String?, artist: String?, year: Int?,
                       cover: Data?, removeCover: Bool) async {
        var override = await override(for: albumID)
        override.title = title
        override.artist = artist
        override.year = year
        let oldCover = override.artworkFile
        if let cover, let file = await Task.detached(priority: .userInitiated, operation: { Self.saveCover(cover) }).value {
            override.artworkFile = file
        } else if removeCover {
            override.artworkFile = nil
        }
        if let oldCover, oldCover != override.artworkFile {
            try? FileManager.default.removeItem(at: AlbumOverrides.coversFolder.appendingPathComponent(oldCover))
        }
        albums = await catalog.setOverride(override)
    }

    /// Clears every edit of the album, including a chosen cover.
    func restoreOriginal(_ albumID: String) async {
        await saveAlbumEdit(albumID, title: nil, artist: nil, year: nil, cover: nil, removeCover: true)
    }

    /// Stores a picked image as a square JPEG (the middle of it) of at most 1500 px.
    /// Returns its file name.
    nonisolated private static func saveCover(_ data: Data) -> String? {
        guard let image = ArtworkStore.squareThumbnail(data, side: 1500),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.9) else { return nil }
        let name = UUID().uuidString + ".jpg"
        let folder = AlbumOverrides.coversFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return name
    }

    /// Moves unreadable tracks to Recently Deleted.
    func moveUnreadableToTrash() async {
        await moveFilesToTrash(unreadableTracks.map(\.id))
    }

    /// Measures the library and Recently Deleted folders in the background.
    func measureStorage() {
        Task { [weak self] in
            let summary = await Task.detached(priority: .utility) {
                StorageSummary.measure(library: LibraryStore.libraryFolder, trash: LibraryStore.trashFolder)
            }.value
            self?.storage = summary
        }
    }

    /// Looks for identical files in the background. Only files of equal size are read.
    private func findDuplicates() {
        duplicateTask?.cancel()
        let index = contentIndex
        duplicateTask = Task { [weak self] in
            let started = Date()
            let groups = await Task.detached(priority: .utility) { () -> [[String]] in
                index.refresh()
                defer { index.save() }
                return index.duplicateGroups()
            }.value
            guard !Task.isCancelled, let self else { return }
            self.duplicateGroups = groups
            print(String(format: "[Closure] duplicate check: %d group(s) in %.0f ms", groups.count, Date().timeIntervalSince(started) * 1000))
        }
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
