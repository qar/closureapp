import Foundation

/// One file in a download job.
struct DownloadItem: Codable, Identifiable, Equatable {
    enum State: Codable, Equatable {
        case queued
        case downloading
        case done
        case failed(String)
        case imported
        /// The library already has a file with the same content (SHA-256); not downloaded
        /// or not added again.
        case alreadyInLibrary
    }

    /// Drive file ID.
    let id: String
    let name: String
    /// Expected size in bytes; 0 when Drive does not report one.
    let size: Int64
    /// Where the file goes inside the job folder, e.g. "Low Light/CD1/01.flac". Top-level
    /// "files/" holds single picked files.
    let relativePath: String
    /// SHA-256 reported by Drive, when it reports one.
    var sha256: String?
    var state: State = .queued
    var received: Int64 = 0
    var attempts = 0

    var isFinished: Bool {
        switch state {
        case .done, .imported, .alreadyInLibrary: return true
        default: return false
        }
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

/// A set of files being downloaded from Google Drive and then imported. Saved to disk,
/// so it survives the app being closed.
struct DownloadJob: Codable, Equatable {
    static let looseFilesFolder = "files"

    var items: [DownloadItem]

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Finished files count fully; files in progress count what has arrived.
    var receivedBytes: Int64 {
        items.reduce(0) { total, item in
            total + (item.isFinished ? item.size : min(item.received, item.size > 0 ? item.size : item.received))
        }
    }

    var finishedCount: Int { items.filter(\.isFinished).count }
    var alreadyInLibraryCount: Int { items.filter { $0.state == .alreadyInLibrary }.count }
    var failedCount: Int { items.filter(\.isFailed).count }
    var activeCount: Int { items.filter { $0.state == .queued || $0.state == .downloading }.count }
    var isActive: Bool { activeCount > 0 }

    /// Fraction for the overall progress bar, by bytes when sizes are known.
    var fraction: Double {
        let total = totalBytes
        if total > 0 { return min(1, Double(receivedBytes) / Double(total)) }
        return items.isEmpty ? 0 : Double(finishedCount) / Double(items.count)
    }

    /// Downloaded files not imported yet. Imported only when nothing is still queued or
    /// downloading, so an album arrives in one piece.
    var readyToImport: [DownloadItem] {
        guard !isActive else { return [] }
        return items.filter { $0.state == .done }
    }

    /// Paths to hand to the importer for `items`: top-level folders once each, single
    /// files one by one.
    static func importSources(for items: [DownloadItem], in root: URL) -> [URL] {
        var folders: [String] = []
        var files: [URL] = []
        for item in items {
            let parts = item.relativePath.split(separator: "/").map(String.init)
            if parts.first == looseFilesFolder, parts.count == 2 {
                files.append(root.appendingPathComponent(item.relativePath))
            } else if let top = parts.first, !folders.contains(top) {
                folders.append(top)
            }
        }
        return folders.map { root.appendingPathComponent($0, isDirectory: true) } + files
    }

    /// Marks files the importer skipped as already in the library. `duplicates` are the
    /// importer's paths: "Album/CD1/01.flac" for folders, the bare name for single files.
    /// A folder whose every track was a duplicate was skipped whole, covers included.
    mutating func markDuplicates(_ duplicates: [String]) {
        guard !duplicates.isEmpty else { return }
        let skipped = Set(duplicates)
        for index in items.indices {
            let path = items[index].relativePath
            let loose = DownloadJob.looseFilesFolder + "/"
            if skipped.contains(path) || (path.hasPrefix(loose) && skipped.contains(String(path.dropFirst(loose.count)))) {
                items[index].state = .alreadyInLibrary
            }
        }
        var tops: [String: [Int]] = [:]
        for index in items.indices {
            guard let top = items[index].relativePath.split(separator: "/").first.map(String.init),
                  top != DownloadJob.looseFilesFolder else { continue }
            tops[top, default: []].append(index)
        }
        for (_, indices) in tops {
            let audio = indices.filter { FileImporter.kind(of: URL(fileURLWithPath: items[$0].name)) == .audio }
            guard !audio.isEmpty, audio.allSatisfy({ items[$0].state == .alreadyInLibrary }) else { continue }
            for index in indices where items[index].state == .imported { items[index].state = .alreadyInLibrary }
        }
    }

    mutating func update(_ id: String, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}

/// Which failures are worth another attempt, and how long to wait.
enum RetryPolicy {
    static let maxAttempts = 5

    static func isTransient(urlErrorCode: Int?, httpStatus: Int?) -> Bool {
        if let status = httpStatus {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        guard let code = urlErrorCode else { return false }
        let transient: Set<Int> = [
            NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
            NSURLErrorSecureConnectionFailed, NSURLErrorResourceUnavailable, NSURLErrorBackgroundSessionWasDisconnected,
        ]
        return transient.contains(code)
    }

    /// 2, 4, 8, 16 … seconds, capped at one minute.
    static func delay(afterAttempt attempt: Int) -> TimeInterval {
        min(60, pow(2, Double(max(1, attempt))))
    }
}

/// Download speed over the last few seconds.
struct SpeedMeter {
    private var samples: [(time: Date, bytes: Int64)] = []
    let window: TimeInterval

    init(window: TimeInterval = 5) {
        self.window = window
    }

    /// Records the total bytes received so far at `time`.
    mutating func record(totalBytes: Int64, at time: Date) {
        samples.append((time, totalBytes))
        samples.removeAll { time.timeIntervalSince($0.time) > window }
    }

    var bytesPerSecond: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let seconds = last.time.timeIntervalSince(first.time)
        guard seconds > 0.5 else { return 0 }
        return max(0, Double(last.bytes - first.bytes) / seconds)
    }

    mutating func reset() { samples.removeAll() }
}
