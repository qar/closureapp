import AVFoundation
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
    private(set) var isImporting = false
    /// The result of the last import, until the user dismisses it.
    var importSummary: ImportSummary?
    /// Recently Deleted, newest first.
    private(set) var trashEntries: [TrashStore.Entry] = []

    nonisolated static var libraryFolder: URL { LibraryPaths.musicFolder }

    /// Bump when the fields read from files change, so every file is read again once.
    private static let indexVersion = 2

    private static let indexFile: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library.json")
    }()

    /// Finder file sharing shows this folder. Files placed here are imported.
    private static let inboxFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    @ObservationIgnored private var tracksByID: [String: Track] = [:]
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
        loadIndex()
        rebuildAlbums()
        trash.purgeExpired()
        trashEntries = trash.entries
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

    // MARK: - Scan and index

    /// Reconciles the index with the files on disk. Unchanged files keep their
    /// cached metadata; new or changed files are read again.
    func rescan() async {
        let root = Self.libraryFolder
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var found: [(id: String, url: URL, size: Int64, modified: Date)] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        while let file = enumerator?.nextObject() as? URL {
            guard Self.isAudio(file),
                  let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let id = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            found.append((id, file, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }

        var updated: [String: Track] = [:]
        for item in found {
            if let cached = tracksByID[item.id], cached.fileSize == item.size, cached.modified == item.modified {
                updated[item.id] = cached
            } else {
                updated[item.id] = await Self.readTrack(id: item.id, url: item.url, size: item.size, modified: item.modified)
            }
        }

        tracksByID = updated
        saveIndex()
        rebuildAlbums()
        await ArtworkStore.shared.forgetMisses()
    }

    private static func readTrack(id: String, url: URL, size: Int64, modified: Date) async -> Track {
        let info = CLSEngine.probe(url.path)
        var items: [TagItem] = []
        if let metadata = try? await AVURLAsset(url: url).load(.metadata) {
            for item in metadata {
                items.append(TagItem(identifier: item.identifier?.rawValue ?? "",
                                     commonKey: item.commonKey?.rawValue,
                                     string: try? await item.load(.stringValue),
                                     number: (try? await item.load(.numberValue))?.intValue,
                                     data: try? await item.load(.dataValue)))
            }
        }
        let tags = TagParser.parse(items)
        let fileName = url.deletingPathExtension().lastPathComponent
        let parentName = url.deletingLastPathComponent().lastPathComponent
        // Without a disc tag, a "CD2" folder still says which disc this is.
        let discFromFolder = LibraryGrouping.discNumber(fromFolderName: parentName)
        let albumFolderName = discFromFolder != nil ? url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent : parentName

        return Track(id: id,
                     title: tags.title ?? fileName,
                     artist: tags.artist ?? "",
                     album: tags.album ?? albumFolderName,
                     // "01 Title.flac" style names when the tag is missing.
                     trackNumber: tags.trackNumber ?? Int(url.lastPathComponent.prefix { $0.isNumber }) ?? 0,
                     duration: info.durationSeconds,
                     codec: info.ok ? info.codec : "Unsupported",
                     sampleRate: info.sampleRate, bitDepth: info.bitDepth, fileSize: size, modified: modified,
                     year: tags.year,
                     albumArtist: tags.albumArtist,
                     discNumber: tags.discNumber ?? discFromFolder,
                     composer: tags.composer,
                     genre: tags.genre,
                     isCompilation: tags.isCompilation)
    }

    private func rebuildAlbums() {
        albums = LibraryGrouping.albums(from: Array(tracksByID.values))
    }

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

    private struct IndexFile: Codable {
        var version: Int
        var tracks: [Track]
    }

    /// An index from an older version (or none) is ignored, so the next scan reads every file.
    private func loadIndex() {
        guard let data = try? Data(contentsOf: Self.indexFile),
              let index = try? JSONDecoder().decode(IndexFile.self, from: data),
              index.version == Self.indexVersion else { return }
        tracksByID = Dictionary(uniqueKeysWithValues: index.tracks.map { ($0.id, $0) })
    }

    private func saveIndex() {
        let index = IndexFile(version: Self.indexVersion, tracks: Array(tracksByID.values))
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: Self.indexFile, options: .atomic)
    }
}
