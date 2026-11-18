import CryptoKit
import Foundation

/// Finds files with the same content, by SHA-256. Never by name, tags or duration.
///
/// Sizes come first: a SHA-256 is computed only for files whose size matches another
/// file, so most files are never read. Computed hashes are cached by path, size and
/// modification date, and saved, so a file is read at most once while it is unchanged.
///
/// Thread-safe; meant for background tasks.
final class ContentIndex: @unchecked Sendable {
    struct CacheEntry: Codable, Equatable {
        var size: Int64
        var modified: Double
        var sha256: String
    }

    let libraryRoot: URL
    private let cacheURL: URL?
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var cacheChanged = false
    /// Library files by size, relative paths. Built by `refresh()`.
    private var bySize: [Int64: [String]] = [:]
    private let fileManager = FileManager.default

    init(libraryRoot: URL, cacheURL: URL?) {
        self.libraryRoot = libraryRoot
        self.cacheURL = cacheURL
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            cache = saved
        }
    }

    // MARK: - Library listing

    /// Lists the library's audio and companion files with their sizes. Call before a
    /// batch of lookups; files added later are made known with `noteAdded`.
    func refresh() {
        var sizes: [Int64: [String]] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let rootPath = libraryRoot.standardizedFileURL.path
        if let walker = fileManager.enumerator(at: libraryRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      Self.isTracked(url), let size = values.fileSize else { continue }
                sizes[Int64(size), default: []].append(Self.relative(url, rootPath: rootPath))
            }
        }
        lock.withLock { bySize = sizes }
    }

    /// Makes a file just placed in the library known to later lookups.
    func noteAdded(_ relativePath: String, sha256: String? = nil) {
        let url = libraryRoot.appendingPathComponent(relativePath)
        guard let stamp = stamp(of: url) else { return }
        lock.withLock {
            if !(bySize[stamp.size]?.contains(relativePath) ?? false) { bySize[stamp.size, default: []].append(relativePath) }
            if let sha256 {
                cache[relativePath] = CacheEntry(size: stamp.size, modified: stamp.modified, sha256: sha256)
                cacheChanged = true
            }
        }
    }

    // MARK: - Lookups

    /// Library files with exactly the content of `size` bytes hashing to `sha256`.
    func libraryFiles(size: Int64, sha256: String) -> [String] {
        let candidates = lock.withLock { bySize[size] ?? [] }
        return candidates.filter { libraryHash(of: $0) == sha256.lowercased() }
    }

    /// Library files with exactly the content of the file at `url`. Reads `url` only when
    /// some library file has the same size.
    func libraryFiles(sameAs url: URL) -> (paths: [String], sha256: String?) {
        guard let size = stamp(of: url)?.size else { return ([], nil) }
        let candidates = lock.withLock { bySize[size] ?? [] }
        guard !candidates.isEmpty, let sha = Self.sha256(of: url) else { return ([], nil) }
        return (candidates.filter { libraryHash(of: $0) == sha }, sha)
    }

    /// Groups of library audio files with identical content, each group sorted by path.
    func duplicateGroups() -> [[String]] {
        let sizes = lock.withLock { bySize }
        var groups: [[String]] = []
        for (_, paths) in sizes where paths.count > 1 {
            let audio = paths.filter { FileImporter.kind(of: URL(fileURLWithPath: $0)) == .audio }
            guard audio.count > 1 else { continue }
            var byHash: [String: [String]] = [:]
            for path in audio {
                if let sha = libraryHash(of: path) { byHash[sha, default: []].append(path) }
            }
            for (_, same) in byHash where same.count > 1 {
                groups.append(same.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
            }
        }
        return groups.sorted { $0[0].localizedStandardCompare($1[0]) == .orderedAscending }
    }

    /// Writes new cache entries to disk.
    func save() {
        guard let cacheURL else { return }
        let snapshot: [String: CacheEntry]? = lock.withLock {
            guard cacheChanged else { return nil }
            cacheChanged = false
            return cache
        }
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - Hashing

    /// The SHA-256 of a library file, from the cache when the file is unchanged.
    private func libraryHash(of relativePath: String) -> String? {
        let url = libraryRoot.appendingPathComponent(relativePath)
        guard let stamp = stamp(of: url) else { return nil }
        if let cached = lock.withLock({ cache[relativePath] }), cached.size == stamp.size, cached.modified == stamp.modified {
            return cached.sha256
        }
        guard let sha = Self.sha256(of: url) else { return nil }
        lock.withLock {
            cache[relativePath] = CacheEntry(size: stamp.size, modified: stamp.modified, sha256: sha)
            cacheChanged = true
        }
        return sha
    }

    /// Lowercase hex SHA-256, the same form Google Drive reports.
    static func sha256(of url: URL) -> String? {
        guard let input = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? input.close() }
        var hasher = SHA256()
        do {
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func stamp(of url: URL) -> (size: Int64, modified: Double)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize else { return nil }
        return (Int64(size), values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
    }

    private static func isTracked(_ url: URL) -> Bool {
        let kind = FileImporter.kind(of: url)
        return kind == .audio || kind == .companion
    }

    private static func relative(_ url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
    }
}

/// Which copy of identical files the Duplicates page keeps by default.
enum DuplicatesViewKeep {
    /// Which copy to keep unless the user picks another. The files are already known to
    /// be identical; this only decides where the one copy stays: in an album folder
    /// rather than among single imports, then the shorter name (no " 2" added on import).
    static func pick(_ group: [String]) -> String {
        group.min { a, b in
            let looseA = a.hasPrefix(FileImporter.looseFilesFolder + "/"), looseB = b.hasPrefix(FileImporter.looseFilesFolder + "/")
            if looseA != looseB { return !looseA }
            if a.count != b.count { return a.count < b.count }
            return a.localizedStandardCompare(b) == .orderedAscending
        } ?? group[0]
    }
}
