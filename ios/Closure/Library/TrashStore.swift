import Foundation

/// Recently Deleted. A deleted track moves out of the library into a trash folder,
/// together with companion files that share its name (lyrics, cue sheets). It can be
/// restored to where it was until it expires; only then is it removed for good.
final class TrashStore {
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        /// Path of the audio file relative to the library root, at deletion time.
        let originalPath: String
        /// Companion files moved with it, also relative to the library root.
        let companions: [String]
        let deletedAt: Date
        let title: String
        let artist: String
        let album: String

        func expires(retention: TimeInterval = TrashStore.retention) -> Date {
            deletedAt.addingTimeInterval(retention)
        }
    }

    enum TrashError: Error {
        case missingFile(String)
    }

    private let libraryRoot: URL
    private let trashRoot: URL
    private let fileManager = FileManager.default
    private(set) var entries: [Entry] = []

    private var indexFile: URL { trashRoot.appendingPathComponent("index.json") }

    init(libraryRoot: URL, trashRoot: URL) {
        self.libraryRoot = libraryRoot
        self.trashRoot = trashRoot
        try? fileManager.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexFile),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// Moves a library file (and its companions) into the trash.
    @discardableResult
    func moveToTrash(relativePath: String, title: String, artist: String, album: String, now: Date = Date()) throws -> Entry {
        let source = libraryRoot.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: source.path) else { throw TrashError.missingFile(relativePath) }

        let id = UUID()
        let holder = trashRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: holder, withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: holder.appendingPathComponent(source.lastPathComponent))

        var companions: [String] = []
        for companion in companionFiles(of: source) {
            let relative = relativeToLibrary(companion)
            if (try? fileManager.moveItem(at: companion, to: holder.appendingPathComponent(companion.lastPathComponent))) != nil {
                companions.append(relative)
            }
        }

        let entry = Entry(id: id, originalPath: relativePath, companions: companions, deletedAt: now,
                          title: title, artist: artist, album: album)
        entries.insert(entry, at: 0)
        save()
        return entry
    }

    /// After an album's tracks are gone: moves what is left in its folder (cover,
    /// booklet) into one trash entry and removes the empty folder. Nothing happens
    /// while the folder still has audio in it. `folder` is library-relative.
    @discardableResult
    func moveLeftoversToTrash(folder: String, album: String, artist: String, now: Date = Date()) -> Entry? {
        let folderURL = libraryRoot.appendingPathComponent(folder, isDirectory: true)
        let items = ((try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        guard !items.contains(where: { FileImporter.kind(of: $0) == .audio }) else { return nil }
        let files = items.filter { FileImporter.kind(of: $0) != .junk }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var entry: Entry?
        if !files.isEmpty {
            let id = UUID()
            let holder = trashRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            try? fileManager.createDirectory(at: holder, withIntermediateDirectories: true)
            var moved: [String] = []
            for file in files where (try? fileManager.moveItem(at: file, to: holder.appendingPathComponent(file.lastPathComponent))) != nil {
                moved.append(relativeToLibrary(file))
            }
            if moved.isEmpty {
                try? fileManager.removeItem(at: holder)
            } else {
                entry = Entry(id: id, originalPath: moved[0], companions: Array(moved.dropFirst()), deletedAt: now,
                              title: "Album files", artist: artist, album: album)
                entries.insert(entry!, at: 0)
                save()
            }
        }
        // Junk and the folder itself are not worth keeping.
        for item in items where FileImporter.kind(of: item) == .junk { try? fileManager.removeItem(at: item) }
        if ((try? fileManager.contentsOfDirectory(atPath: folderURL.path)) ?? []).isEmpty {
            try? fileManager.removeItem(at: folderURL)
        }
        return entry
    }

    /// Moves the files back. If the original path is taken, the file gets a new name.
    /// Returns the library-relative path the audio file was restored to.
    @discardableResult
    func restore(_ entry: Entry) throws -> String {
        let holder = trashRoot.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        let audioName = (entry.originalPath as NSString).lastPathComponent
        let target = uniqueURL(for: libraryRoot.appendingPathComponent(entry.originalPath))
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: holder.appendingPathComponent(audioName), to: target)

        for companion in entry.companions {
            let name = (companion as NSString).lastPathComponent
            let destination = uniqueURL(for: libraryRoot.appendingPathComponent(companion))
            try? fileManager.moveItem(at: holder.appendingPathComponent(name), to: destination)
        }
        try? fileManager.removeItem(at: holder)
        entries.removeAll { $0.id == entry.id }
        save()
        return relativeToLibrary(target)
    }

    func deletePermanently(_ entry: Entry) {
        try? fileManager.removeItem(at: trashRoot.appendingPathComponent(entry.id.uuidString, isDirectory: true))
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// Removes entries older than the retention period. Returns what was removed.
    @discardableResult
    func purgeExpired(now: Date = Date(), retention: TimeInterval = TrashStore.retention) -> [Entry] {
        let expired = entries.filter { $0.expires(retention: retention) <= now }
        for entry in expired { deletePermanently(entry) }
        return expired
    }

    // MARK: - Helpers

    /// Files next to `audio` with the same base name and a companion extension.
    private func companionFiles(of audio: URL) -> [URL] {
        let stem = audio.deletingPathExtension().lastPathComponent
        let siblings = (try? fileManager.contentsOfDirectory(at: audio.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return siblings.filter {
            $0.deletingPathExtension().lastPathComponent == stem
                && FileImporter.kind(of: $0) == .companion
        }
    }

    private func relativeToLibrary(_ url: URL) -> String {
        let root = libraryRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent
    }

    private func uniqueURL(for url: URL) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while true {
            var candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(counter)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexFile, options: .atomic)
    }
}
