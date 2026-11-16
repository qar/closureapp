import CryptoKit
import Foundation

/// Moves or copies audio folders into the library. It never deletes a file it has not
/// transferred, so a failed or partial import leaves the source as it was.
///
/// - Audio and companion files (cover images, lyrics, cue sheets, logs, booklets) keep
///   their relative paths, so a cover or .lrc file stays next to its tracks.
/// - System junk (.DS_Store, AppleDouble files) is dropped.
/// - Anything else stays where it is and is reported.
/// - A folder without audio is left alone completely.
///
/// Copies (from the Files app) go through a staging folder: each file is copied with
/// a SHA-256 of the source, read back and compared, and only a fully verified folder is
/// moved into the library. A manifest marks a verified staging folder, so an import
/// interrupted after verification finishes on the next launch; anything unverified is
/// discarded (the source is untouched). Before copying, the total size is checked
/// against the free space.
struct FileImporter {
    enum Mode {
        /// From the Files app: the source belongs to the user and is never changed.
        case copy
        /// From the app's Documents inbox: transferred files leave the inbox.
        case move
    }

    enum Kind: Equatable {
        case audio
        case companion
        case junk
        case other
    }

    struct Report: Equatable {
        var audioFiles = 0
        var companionFiles = 0
        /// Files that could not be transferred. In move mode they are still in the inbox.
        var failed: [String] = []
        /// Files left in the inbox because Closure does not handle them.
        var leftInPlace: [String] = []
        /// Bytes missing when an import did not start for lack of space.
        var spaceShortfall: Int64?

        mutating func merge(_ other: Report) {
            audioFiles += other.audioFiles
            companionFiles += other.companionFiles
            failed += other.failed
            leftInPlace += other.leftInPlace
            if let shortfall = other.spaceShortfall { spaceShortfall = (spaceShortfall ?? 0) + shortfall }
        }
    }

    static let audioExtensions: Set<String> = ["flac", "m4a", "alac", "aac", "mp3", "wav", "aif", "aiff", "caf"]
    static let companionExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic",
                                                    "lrc", "cue", "log", "m3u", "m3u8",
                                                    "pdf", "txt", "nfo"]
    /// Single files go here. Folders keep their own name at the library root.
    static let looseFilesFolder = "Imported"
    /// iOS puts files opened from the share sheet into Documents/Inbox.
    static let systemInboxName = "Inbox"
    private static let manifestName = "manifest.json"
    /// Kept free after an import, so the system never runs completely out of space.
    static let spaceReserve: Int64 = 200 * 1024 * 1024

    let libraryRoot: URL
    let stagingRoot: URL
    /// Free bytes on the library's volume. Injected by tests.
    var availableSpace: () -> Int64?
    /// Test hook: called after a file is staged and before it is verified.
    var afterStaging: ((URL) -> Void)?
    private let fileManager = FileManager.default

    init(libraryRoot: URL, stagingRoot: URL? = nil, availableSpace: (() -> Int64?)? = nil) {
        self.libraryRoot = libraryRoot
        self.stagingRoot = stagingRoot ?? libraryRoot.deletingLastPathComponent().appendingPathComponent("Staging", isDirectory: true)
        self.availableSpace = availableSpace ?? {
            let values = try? libraryRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }
    }

    static func kind(of url: URL) -> Kind {
        let name = url.lastPathComponent
        if name == ".DS_Store" || name == "Thumbs.db" || name == "desktop.ini" || name.hasPrefix("._") {
            return .junk
        }
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        if companionExtensions.contains(ext) { return .companion }
        return .other
    }

    // MARK: - Entry points

    /// Copies files and folders picked in the Files app. Checks free space first; if it
    /// is short, nothing is copied.
    func importCopies(_ sources: [URL]) -> Report {
        let scoped = sources.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer { for (url, didStart) in scoped where didStart { url.stopAccessingSecurityScopedResource() } }

        let needed = sources.reduce(Int64(0)) { $0 + transferableBytes(in: $1) }
        if let free = availableSpace(), needed + Self.spaceReserve > free {
            var report = Report()
            report.spaceShortfall = needed + Self.spaceReserve - free
            return report
        }
        var report = Report()
        for source in sources { report.merge(importItem(source, mode: .copy)) }
        return report
    }

    /// Imports everything in the Documents inbox. Items Closure cannot use stay there.
    func importInbox(_ inbox: URL) -> Report {
        var report = Report()
        for item in children(of: inbox) {
            if item.lastPathComponent == Self.systemInboxName, isDirectory(item) {
                // Share sheet files: each is a loose file, not an album folder.
                for file in children(of: item) {
                    report.merge(importItem(file, mode: .move))
                }
                removeIfEmpty(item)
            } else {
                report.merge(importItem(item, mode: .move))
            }
        }
        return report
    }

    /// Imports one file or folder.
    func importItem(_ source: URL, mode: Mode) -> Report {
        guard fileManager.fileExists(atPath: source.path) else { return Report() }
        return isDirectory(source) ? importFolder(source, mode: mode) : importLooseFile(source, mode: mode)
    }

    /// Finishes verified imports that were interrupted and discards unverified ones.
    /// Returns what was finished.
    @discardableResult
    func recoverStaging() -> Report {
        var report = Report()
        for batch in children(of: stagingRoot) where isDirectory(batch) {
            if fileManager.fileExists(atPath: batch.appendingPathComponent(Self.manifestName).path) {
                report.merge(commit(batch))
            } else {
                try? fileManager.removeItem(at: batch)
            }
        }
        return report
    }

    // MARK: - Folders

    private func importFolder(_ folder: URL, mode: Mode) -> Report {
        let files = regularFiles(in: folder)
        var report = Report()

        // A folder of photos or documents is not music. Leave it untouched.
        guard files.contains(where: { Self.kind(of: $0) == .audio }) else {
            if mode == .move { report.leftInPlace.append(folder.lastPathComponent) }
            return report
        }

        var staged: [(source: URL, relative: String)] = []
        for file in files {
            let kind = Self.kind(of: file)
            switch kind {
            case .audio, .companion:
                let relative = folder.lastPathComponent + "/" + relativePath(of: file, in: folder)
                if mode == .move {
                    if move(file, to: libraryRoot.appendingPathComponent(relative)) {
                        if kind == .audio { report.audioFiles += 1 } else { report.companionFiles += 1 }
                    } else {
                        report.failed.append(relative)
                    }
                } else {
                    staged.append((file, relative))
                }
            case .junk:
                if mode == .move { try? fileManager.removeItem(at: file) }
            case .other:
                if mode == .move { report.leftInPlace.append(relativePath(of: file, in: folder.deletingLastPathComponent())) }
            }
        }

        if mode == .copy {
            report.merge(copyThroughStaging(staged))
        } else {
            removeEmptyDirectories(in: folder)
        }
        return report
    }

    // MARK: - Loose files

    private func importLooseFile(_ file: URL, mode: Mode) -> Report {
        var report = Report()
        switch Self.kind(of: file) {
        case .audio:
            let relative = Self.looseFilesFolder + "/" + file.lastPathComponent
            if mode == .copy {
                return copyThroughStaging([(file, relative)])
            }
            if move(file, to: libraryRoot.appendingPathComponent(relative)) {
                report.audioFiles += 1
            } else {
                report.failed.append(file.lastPathComponent)
            }
        case .junk:
            if mode == .move { try? fileManager.removeItem(at: file) }
        case .companion, .other:
            // A cover or lyrics file on its own has no album to attach to.
            if mode == .move { report.leftInPlace.append(file.lastPathComponent) }
        }
        return report
    }

    // MARK: - Staged copies

    private struct Manifest: Codable {
        var files: [String]
    }

    /// Copies each file into a fresh staging folder and verifies it. Files that fail are
    /// reported and left out; the rest are marked verified and moved into the library.
    private func copyThroughStaging(_ files: [(source: URL, relative: String)]) -> Report {
        guard !files.isEmpty else { return Report() }
        var report = Report()
        let batch = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var verified: [String] = []
        for (source, relative) in files {
            let staged = batch.appendingPathComponent(relative)
            if copyVerified(from: source, to: staged) {
                verified.append(relative)
            } else {
                try? fileManager.removeItem(at: staged)
                report.failed.append(relative)
            }
        }
        guard !verified.isEmpty,
              let data = try? JSONEncoder().encode(Manifest(files: verified)),
              (try? data.write(to: batch.appendingPathComponent(Self.manifestName), options: .atomic)) != nil else {
            try? fileManager.removeItem(at: batch)
            return report
        }
        report.merge(commit(batch))
        return report
    }

    /// Moves a verified staging folder into the library. Same volume, so each move is a rename.
    private func commit(_ batch: URL) -> Report {
        var report = Report()
        guard let data = try? Data(contentsOf: batch.appendingPathComponent(Self.manifestName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return report }
        for relative in manifest.files {
            let staged = batch.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: staged.path) else { continue } // already moved before an interruption
            if move(staged, to: libraryRoot.appendingPathComponent(relative)) {
                if Self.kind(of: staged) == .audio { report.audioFiles += 1 } else { report.companionFiles += 1 }
            } else {
                report.failed.append(relative)
            }
        }
        try? fileManager.removeItem(at: batch)
        return report
    }

    /// Copies through a file coordinator (which downloads iCloud files first), hashing
    /// the source while writing, then reads the copy back and compares.
    private func copyVerified(from source: URL, to destination: URL) -> Bool {
        var succeeded = false
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let sourceHash = try streamCopy(from: readable, to: destination)
                afterStaging?(destination)
                succeeded = try hash(of: destination) == sourceHash
            } catch {
                succeeded = false
            }
        }
        return succeeded && coordinationError == nil
    }

    private func streamCopy(from source: URL, to destination: URL) throws -> SHA256.Digest {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        return hasher.finalize()
    }

    private func hash(of url: URL) throws -> SHA256.Digest {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    /// Bytes of audio and companion files that an import of `source` would copy.
    private func transferableBytes(in source: URL) -> Int64 {
        let files = isDirectory(source) ? regularFiles(in: source) : [source]
        return files.reduce(Int64(0)) { total, file in
            let kind = Self.kind(of: file)
            guard kind == .audio || kind == .companion else { return total }
            return total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: - Moves

    /// Same-volume move: a rename, so the file is never in two half states. The source
    /// is gone only when the move succeeded.
    private func move(_ source: URL, to destination: URL) -> Bool {
        let target = uniqueURL(for: destination)
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: target)
            return true
        } catch {
            return false
        }
    }

    private func uniqueURL(for url: URL) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        var counter = 2
        while true {
            var candidate = folder.appendingPathComponent("\(base) \(counter)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    // MARK: - File system helpers

    private func children(of folder: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    private func regularFiles(in folder: URL) -> [URL] {
        var files: [URL] = []
        let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let item = enumerator?.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(item)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func relativePath(of file: URL, in folder: URL) -> String {
        let folderPath = folder.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(folderPath) else { return file.lastPathComponent }
        return String(filePath.dropFirst(folderPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Deletes directories that hold nothing, deepest first. A directory with any file
    /// left in it is kept.
    private func removeEmptyDirectories(in folder: URL) {
        var directories: [URL] = [folder]
        let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        while let item = enumerator?.nextObject() as? URL {
            if isDirectory(item) { directories.append(item) }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            removeIfEmpty(directory)
        }
    }

    private func removeIfEmpty(_ directory: URL) {
        if children(of: directory).isEmpty {
            try? fileManager.removeItem(at: directory)
        }
    }
}
