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
/// Imports go through a staging folder: each file is copied with
/// a SHA-256 of the source, read back and compared, and only a fully verified folder is
/// moved into the library. A manifest marks a verified staging folder, so an import
/// interrupted after verification finishes on the next launch; anything unverified is
/// discarded (the source is untouched). Finder sources leave Documents after commit.
///
/// With a content index, a file whose exact content (SHA-256) is already in the library
/// is skipped and reported as a duplicate. Names are never compared.
struct FileImporter {
    enum Mode {
        /// From the Files app: the source belongs to the user and is never changed.
        case copy
        /// From the app's Documents inbox: transferred files leave after verification.
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
        /// Audio files skipped because the library already has the same content.
        var duplicates: [String] = []

        mutating func merge(_ other: Report) {
            audioFiles += other.audioFiles
            companionFiles += other.companionFiles
            failed += other.failed
            leftInPlace += other.leftInPlace
            duplicates += other.duplicates
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
    /// Test hook: called before a verified item enters the library.
    var beforeCommitMove: ((URL, URL) throws -> Void)?
    /// Finds content already in the library. Without it, nothing is treated as a duplicate.
    var contentIndex: ContentIndex?
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
        contentIndex?.refresh()
        defer { contentIndex?.save() }
        var report = Report()
        for source in sources { report.merge(importItem(source, mode: .copy)) }
        return report
    }

    /// Imports everything in the Documents inbox. Items Closure cannot use stay there.
    func importInbox(_ inbox: URL) -> Report {
        contentIndex?.refresh()
        defer { contentIndex?.save() }
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

        // Audio already in the library (same content) is skipped. When every track is,
        // the whole folder is: its covers and lyrics are already there too.
        let audio = files.filter { Self.kind(of: $0) == .audio }
        let duplicateAudio = Set(audio.filter { isInLibrary($0) })
        if !audio.isEmpty, duplicateAudio.count == audio.count {
            report.duplicates = audio.map { folder.lastPathComponent + "/" + relativePath(of: $0, in: folder) }
            if mode == .move {
                for file in files where Self.kind(of: file) != .other { try? fileManager.removeItem(at: file) }
                removeEmptyDirectories(in: folder)
            }
            return report
        }

        var staged: [(source: URL, relative: String)] = []
        var skipped: [URL] = []
        for file in files {
            let kind = Self.kind(of: file)
            if duplicateAudio.contains(file) {
                report.duplicates.append(folder.lastPathComponent + "/" + relativePath(of: file, in: folder))
                skipped.append(file)
                continue
            }
            switch kind {
            case .audio, .companion:
                let relative = folder.lastPathComponent + "/" + relativePath(of: file, in: folder)
                // A cover or lyrics file identical to one already beside it is not copied again.
                if kind == .companion, isAlreadyBeside(file, at: relative) {
                    skipped.append(file)
                    continue
                }
                staged.append((file, relative))
            case .junk:
                skipped.append(file)
            case .other:
                if mode == .move { report.leftInPlace.append(relativePath(of: file, in: folder.deletingLastPathComponent())) }
            }
        }

        let stagedReport = copyThroughStaging(staged)
        if mode == .move, stagedReport.failed.isEmpty, stagedReport.spaceShortfall == nil {
            for file in staged.map(\.source) + skipped { try? fileManager.removeItem(at: file) }
        }
        report.merge(stagedReport)
        if mode == .move {
            removeEmptyDirectories(in: folder)
        }
        return report
    }

    // MARK: - Loose files

    private func importLooseFile(_ file: URL, mode: Mode) -> Report {
        var report = Report()
        switch Self.kind(of: file) {
        case .audio where isInLibrary(file):
            report.duplicates.append(file.lastPathComponent)
            if mode == .move { try? fileManager.removeItem(at: file) }
        case .audio:
            let relative = Self.looseFilesFolder + "/" + file.lastPathComponent
            report = copyThroughStaging([(file, relative)])
            if mode == .move, report.failed.isEmpty, report.spaceShortfall == nil {
                try? fileManager.removeItem(at: file)
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
        var version: Int? = 2
        var destinations: [String: String]? = nil
        var atomicRoot: String? = nil
    }

    /// Stages every file in one picked folder. Any failed copy aborts the whole batch.
    private func copyThroughStaging(_ files: [(source: URL, relative: String)]) -> Report {
        guard !files.isEmpty else { return Report() }
        var report = Report()
        let needed = files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        if let free = availableSpace(), needed + Self.spaceReserve > free {
            report.spaceShortfall = needed + Self.spaceReserve - free
            return report
        }
        let batch = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var failed = false
        for (source, relative) in files {
            let staged = batch.appendingPathComponent(relative)
            if !copyVerified(from: source, to: staged) { failed = true }
        }
        guard !failed,
              let data = try? JSONEncoder().encode(Manifest(files: files.map(\.relative))),
              (try? data.write(to: batch.appendingPathComponent(Self.manifestName), options: .atomic)) != nil else {
            try? fileManager.removeItem(at: batch)
            report.failed = files.map(\.relative)
            return report
        }
        report.merge(commit(batch))
        return report
    }

    /// A new album is renamed as one directory. Existing folders use a persisted
    /// destination map so a restart can finish the same moves without new names.
    private func commit(_ batch: URL) -> Report {
        var report = Report()
        let manifestURL = batch.appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              !manifest.files.isEmpty,
              manifest.files.allSatisfy(isSafeRelativePath) else {
            report.failed = [batch.lastPathComponent]
            return report
        }

        if manifest.version == nil, manifest.destinations == nil, manifest.atomicRoot == nil {
            // Older manifests did not record where files already moved before a crash.
            manifest.files.removeAll { !fileManager.fileExists(atPath: batch.appendingPathComponent($0).path) }
            if manifest.files.isEmpty {
                try? fileManager.removeItem(at: batch)
                return report
            }
        }

        if manifest.atomicRoot == nil, manifest.destinations == nil {
            let root = String(manifest.files[0].split(separator: "/")[0])
            let isOneFolder = manifest.files.allSatisfy { $0.hasPrefix(root + "/") }
            if isOneFolder, !fileManager.fileExists(atPath: libraryRoot.appendingPathComponent(root).path) {
                manifest.atomicRoot = root
            } else {
                var reserved: Set<String> = []
                manifest.destinations = Dictionary(uniqueKeysWithValues: manifest.files.map { relative in
                    let target = uniqueURL(for: libraryRoot.appendingPathComponent(relative), reserved: reserved)
                    reserved.insert(target.path)
                    return (relative, String(target.path.dropFirst(libraryRoot.path.count + 1)))
                })
            }
            guard let updated = try? JSONEncoder().encode(manifest),
                  (try? updated.write(to: manifestURL, options: .atomic)) != nil else {
                report.failed = manifest.files
                return report
            }
        }

        if let root = manifest.atomicRoot {
            guard isSafeRelativePath(root) else {
                report.failed = manifest.files
                return report
            }
            let stagedRoot = batch.appendingPathComponent(String(manifest.files[0].split(separator: "/")[0]))
            let targetRoot = libraryRoot.appendingPathComponent(root)
            if fileManager.fileExists(atPath: stagedRoot.path) {
                do {
                    guard !fileManager.fileExists(atPath: targetRoot.path) else { throw CocoaError(.fileWriteFileExists) }
                    try fileManager.createDirectory(at: targetRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try beforeCommitMove?(stagedRoot, targetRoot)
                    try fileManager.moveItem(at: stagedRoot, to: targetRoot)
                } catch {
                    report.failed = manifest.files
                    return report
                }
            }
            guard manifest.files.allSatisfy({ relative in
                let suffix = relative.dropFirst(stagedRoot.lastPathComponent.count + 1)
                return fileManager.fileExists(atPath: targetRoot.appendingPathComponent(String(suffix)).path)
            }) else {
                report.failed = manifest.files
                return report
            }
            for relative in manifest.files {
                let suffix = relative.dropFirst(stagedRoot.lastPathComponent.count + 1)
                let destination = root + "/" + suffix
                contentIndex?.noteAdded(destination)
                if Self.kind(of: URL(fileURLWithPath: relative)) == .audio { report.audioFiles += 1 }
                else { report.companionFiles += 1 }
            }
        } else if let destinations = manifest.destinations,
                  manifest.files.allSatisfy({ destinations[$0].map(isSafeRelativePath) == true }) {
            var succeeded = true
            for relative in manifest.files {
                let staged = batch.appendingPathComponent(relative)
                let target = libraryRoot.appendingPathComponent(destinations[relative]!)
                if fileManager.fileExists(atPath: staged.path) {
                    do {
                        guard !fileManager.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
                        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try beforeCommitMove?(staged, target)
                        try fileManager.moveItem(at: staged, to: target)
                    } catch {
                        succeeded = false
                        break
                    }
                } else if !fileManager.fileExists(atPath: target.path) {
                    succeeded = false
                    break
                }
            }
            if !succeeded {
                for relative in manifest.files.reversed() {
                    let staged = batch.appendingPathComponent(relative)
                    let target = libraryRoot.appendingPathComponent(destinations[relative]!)
                    if !fileManager.fileExists(atPath: staged.path), fileManager.fileExists(atPath: target.path) {
                        try? fileManager.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? fileManager.moveItem(at: target, to: staged)
                    }
                }
                report.failed = manifest.files
                return report
            }
            for relative in manifest.files {
                contentIndex?.noteAdded(destinations[relative]!)
                if Self.kind(of: URL(fileURLWithPath: relative)) == .audio { report.audioFiles += 1 }
                else { report.companionFiles += 1 }
            }
        } else {
            report.failed = manifest.files
            return report
        }
        try? fileManager.removeItem(at: manifestURL)
        try? fileManager.removeItem(at: batch)
        return report
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0.isEmpty || $0 == "." || $0 == ".."
        }
    }

    /// Copies through a file coordinator (which downloads iCloud files first), hashing
    /// the source while writing, then reads the copy back and compares.
    private func copyVerified(from source: URL, to destination: URL) -> Bool {
        var succeeded = false
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let (sourceHash, copiedBytes) = try streamCopy(from: readable, to: destination)
                afterStaging?(destination)
                let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
                let copiedHash = try hash(of: destination)
                succeeded = size.map(Int64.init) == copiedBytes && copiedHash == sourceHash
            } catch {
                succeeded = false
            }
        }
        return succeeded && coordinationError == nil
    }

    private func streamCopy(from source: URL, to destination: URL) throws -> (SHA256.Digest, Int64) {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            bytes += Int64(chunk.count)
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        return (hasher.finalize(), bytes)
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

    // MARK: - Duplicates

    private func isInLibrary(_ file: URL) -> Bool {
        guard let contentIndex else { return false }
        return !contentIndex.libraryFiles(sameAs: file).paths.isEmpty
    }

    /// True when the folder `relative` goes to already holds a file with this content.
    private func isAlreadyBeside(_ file: URL, at relative: String) -> Bool {
        guard let contentIndex else { return false }
        let folder = (relative as NSString).deletingLastPathComponent
        return contentIndex.libraryFiles(sameAs: file).paths.contains { ($0 as NSString).deletingLastPathComponent == folder }
    }

    private func uniqueURL(for url: URL, reserved: Set<String> = []) -> URL {
        guard fileManager.fileExists(atPath: url.path) || reserved.contains(url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        var counter = 2
        while true {
            var candidate = folder.appendingPathComponent("\(base) \(counter)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !fileManager.fileExists(atPath: candidate.path), !reserved.contains(candidate.path) { return candidate }
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
