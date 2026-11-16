import Foundation

/// Moves or copies audio folders into the library. It never deletes a file it has not
/// transferred, so a failed or partial import leaves the source as it was.
///
/// - Audio and companion files (cover images, lyrics, cue sheets, logs, booklets) keep
///   their relative paths, so a cover or .lrc file stays next to its tracks.
/// - System junk (.DS_Store, AppleDouble files) is dropped.
/// - Anything else stays where it is and is reported.
/// - A folder without audio is left alone completely.
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

        mutating func merge(_ other: Report) {
            audioFiles += other.audioFiles
            companionFiles += other.companionFiles
            failed += other.failed
            leftInPlace += other.leftInPlace
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

    let libraryRoot: URL
    private let fileManager = FileManager.default

    init(libraryRoot: URL) {
        self.libraryRoot = libraryRoot
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

    // MARK: - Folders

    private func importFolder(_ folder: URL, mode: Mode) -> Report {
        let files = regularFiles(in: folder)
        var report = Report()

        // A folder of photos or documents is not music. Leave it untouched.
        guard files.contains(where: { Self.kind(of: $0) == .audio }) else {
            if mode == .move { report.leftInPlace.append(folder.lastPathComponent) }
            return report
        }

        let destinationRoot = libraryRoot.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        for file in files {
            let kind = Self.kind(of: file)
            switch kind {
            case .audio, .companion:
                let relative = relativePath(of: file, in: folder)
                if transfer(file, to: destinationRoot.appendingPathComponent(relative), mode: mode) {
                    if kind == .audio { report.audioFiles += 1 } else { report.companionFiles += 1 }
                } else {
                    report.failed.append(relativePath(of: file, in: folder.deletingLastPathComponent()))
                }
            case .junk:
                if mode == .move { try? fileManager.removeItem(at: file) }
            case .other:
                if mode == .move { report.leftInPlace.append(relativePath(of: file, in: folder.deletingLastPathComponent())) }
            }
        }

        if mode == .move { removeEmptyDirectories(in: folder) }
        return report
    }

    // MARK: - Loose files

    private func importLooseFile(_ file: URL, mode: Mode) -> Report {
        var report = Report()
        switch Self.kind(of: file) {
        case .audio:
            let destination = libraryRoot.appendingPathComponent(Self.looseFilesFolder, isDirectory: true)
                .appendingPathComponent(file.lastPathComponent)
            if transfer(file, to: destination, mode: mode) {
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

    // MARK: - Transfer

    /// Returns true only when the file is complete at the destination. In move mode the
    /// source is gone only after that; in copy mode the source is never touched.
    private func transfer(_ source: URL, to destination: URL, mode: Mode) -> Bool {
        let target = uniqueURL(for: destination)
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch mode {
            case .move:
                // Same volume: a rename, so the file is never in two half states.
                try fileManager.moveItem(at: source, to: target)
                return true
            case .copy:
                try fileManager.copyItem(at: source, to: target)
                guard size(of: target) == size(of: source) else {
                    try? fileManager.removeItem(at: target)
                    return false
                }
                return true
            }
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

    private func size(of url: URL) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
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
