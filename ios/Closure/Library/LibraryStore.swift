import AVFoundation
import Foundation
import Observation

struct Track: Identifiable, Hashable, Codable {
    /// Path relative to the library folder. The app container moves between installs
    /// and updates, so absolute paths are never stored.
    let id: String
    var title: String
    var artist: String
    var album: String
    var trackNumber: Int
    var duration: Double
    var codec: String
    var sampleRate: Double
    var bitDepth: Int
    var fileSize: Int64
    var modified: Date

    var url: URL { LibraryStore.libraryFolder.appendingPathComponent(id) }

    var formatSummary: String {
        var parts = [codec]
        if bitDepth > 0 { parts.append("\(bitDepth)-bit") }
        if sampleRate > 0 { parts.append(String(format: "%g kHz", sampleRate / 1000)) }
        return parts.joined(separator: " · ")
    }
}

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]
}

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
    private(set) var lastImportMessage: String?

    nonisolated static let libraryFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Music", isDirectory: true)
    }()

    private static let indexFile: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library.json")
    }()

    /// Finder file sharing shows this folder. Files placed here are imported.
    private static let inboxFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    @ObservationIgnored private var tracksByID: [String: Track] = [:]
    @ObservationIgnored private let importer = FileImporter(libraryRoot: LibraryStore.libraryFolder)

    init() {
        prepareFolders()
        loadIndex()
        rebuildAlbums()
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
        lastImportMessage = Self.describe(report, source: nil)
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
        lastImportMessage = Self.describe(report, source: "Documents")
    }

    func delete(_ track: Track) async {
        try? FileManager.default.removeItem(at: track.url)
        await rescan()
    }

    private static func describe(_ report: FileImporter.Report, source: String?) -> String {
        var parts: [String] = []
        if report.audioFiles == 0 && report.failed.isEmpty {
            parts.append("No audio files found")
        } else {
            var imported = "Imported \(report.audioFiles) track\(report.audioFiles == 1 ? "" : "s")"
            if report.companionFiles > 0 {
                imported += " and \(report.companionFiles) cover, lyrics or other file\(report.companionFiles == 1 ? "" : "s")"
            }
            if let source { imported += " from \(source)" }
            parts.append(imported)
        }
        if !report.failed.isEmpty {
            parts.append("\(report.failed.count) could not be imported and were left in place: "
                         + report.failed.prefix(3).joined(separator: ", ")
                         + (report.failed.count > 3 ? ", …" : ""))
        }
        if !report.leftInPlace.isEmpty, let source {
            parts.append("\(report.leftInPlace.count) item\(report.leftInPlace.count == 1 ? "" : "s") left in \(source)")
        }
        return parts.joined(separator: ". ")
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
    }

    private static func readTrack(id: String, url: URL, size: Int64, modified: Date) async -> Track {
        let info = CLSEngine.probe(url.path)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        var album = url.deletingLastPathComponent().lastPathComponent
        var trackNumber = 0

        let asset = AVURLAsset(url: url)
        if let items = try? await asset.load(.metadata) {
            for item in items {
                switch item.commonKey {
                case .commonKeyTitle?:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { title = value }
                case .commonKeyArtist?:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { artist = value }
                case .commonKeyAlbumName?:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { album = value }
                default:
                    break
                }

                if let identifier = item.identifier,
                   identifier == .iTunesMetadataTrackNumber || identifier == .id3MetadataTrackNumber {
                    trackNumber = await Self.trackNumber(from: item)
                }
            }
        }

        if trackNumber == 0 {
            // "01 Title.flac" style names.
            trackNumber = Int(url.lastPathComponent.prefix { $0.isNumber }) ?? 0
        }

        return Track(id: id, title: title, artist: artist, album: album, trackNumber: trackNumber,
                     duration: info.durationSeconds, codec: info.ok ? info.codec : "Unsupported",
                     sampleRate: info.sampleRate, bitDepth: info.bitDepth, fileSize: size, modified: modified)
    }

    private static func trackNumber(from item: AVMetadataItem) async -> Int {
        if let number = try? await item.load(.numberValue) { return number.intValue }
        if let string = try? await item.load(.stringValue) {
            return Int(string.split(separator: "/").first ?? "") ?? 0
        }
        if let data = try? await item.load(.dataValue), data.count >= 4 {
            // iTunes 'trkn' atom: 2 bytes padding, then a big-endian 16-bit number.
            return Int(data[2]) << 8 | Int(data[3])
        }
        return 0
    }

    private func rebuildAlbums() {
        let grouped = Dictionary(grouping: tracksByID.values) { track in
            "\(track.album)\u{1F}\(track.id.split(separator: "/").dropLast().joined(separator: "/"))"
        }
        albums = grouped.map { key, tracks in
            let sorted = tracks.sorted { first, second in
                if first.trackNumber != second.trackNumber { return first.trackNumber < second.trackNumber }
                return first.id.localizedStandardCompare(second.id) == .orderedAscending
            }
            let artists = Set(sorted.map(\.artist).filter { !$0.isEmpty })
            return Album(id: key,
                         title: sorted.first?.album ?? "Unknown Album",
                         artist: artists.count == 1 ? artists.first! : (artists.isEmpty ? "Unknown Artist" : "Various Artists"),
                         tracks: sorted)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
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

    private func loadIndex() {
        guard let data = try? Data(contentsOf: Self.indexFile),
              let tracks = try? JSONDecoder().decode([Track].self, from: data) else { return }
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(Array(tracksByID.values)) else { return }
        try? data.write(to: Self.indexFile, options: .atomic)
    }
}
