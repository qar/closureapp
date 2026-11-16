import Foundation
import Observation
import os

/// Downloads picked Google Drive files and folders, then imports them.
///
/// - Files download in a background URLSession, so they continue while the app is in
///   the background. The job is saved to disk and picked up again after a relaunch.
/// - In the foreground, three files download at a time, so each file shows steady
///   progress. In the background, everything left is handed to the system at once.
/// - Network failures and server errors are retried automatically, resuming from where
///   the file stopped when the server allows it. Other failures wait for the user.
/// - Downloaded files are imported only when nothing else is still on its way, so an
///   album arrives in one piece.
@MainActor
@Observable
final class DriveDownloadManager: NSObject {
    /// The current job. Kept after it finishes, so the Downloads page can show the result.
    private(set) var job: DownloadJob?
    /// True while folders are listed before the first download.
    private(set) var isPreparing = false
    /// Files listed so far while preparing.
    private(set) var preparedCount = 0
    private(set) var bytesPerSecond: Double = 0
    /// When each waiting retry starts, by file ID.
    private(set) var retryAt: [String: Date] = [:]
    /// A problem with the job as a whole (listing failed, not enough space, signed out).
    private(set) var problem: String?
    /// Audio files added to the library by this job.
    private(set) var importedAudioCount = 0

    var hasJob: Bool { job != nil || isPreparing }
    var isWorking: Bool { isPreparing || (job?.isActive ?? false) || isImportingFiles }
    private(set) var isImportingFiles = false

    /// Copies finished files into the library.
    @ObservationIgnored var importFiles: (([URL]) async -> FileImporter.Report)?

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let accessToken: () async throws -> String
    @ObservationIgnored private let configuration: URLSessionConfiguration
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var resumeData: [String: Data] = [:]
    @ObservationIgnored private var retryTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var meter = SpeedMeter()
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored var foregroundLimit = 3
    /// Debug demo: show a canned job and never download.
    @ObservationIgnored private var isDemo = false
    /// Wait before retry n. Tests shorten it.
    @ObservationIgnored var retryDelay: (Int) -> TimeInterval = RetryPolicy.delay(afterAttempt:)
    /// Throttles progress reports from the session queue to a few per second per file.
    @ObservationIgnored private nonisolated let progressGate = OSAllocatedUnfairLock(initialState: [String: Date]())
    /// Set by the app delegate when the system relaunches the app for download events.
    static var backgroundEventsDone: (() -> Void)?

    static let sessionIdentifier = "com.qar.closure.drive-downloads"

    /// `root` holds the saved job and the downloaded files. `configuration` is a
    /// background configuration in the app; tests pass an ephemeral one.
    init(root: URL, configuration: URLSessionConfiguration, accessToken: @escaping () async throws -> String) {
        self.root = root
        self.configuration = configuration
        self.accessToken = accessToken
        super.init()
        configuration.timeoutIntervalForRequest = 120
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        try? FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = root
        try? folder.setResourceValues(values)
        restore()
    }

    static func appConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return configuration
    }

    static var appRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    var filesRoot: URL { root.appendingPathComponent("files", isDirectory: true) }
    private var jobURL: URL { root.appendingPathComponent("job.json") }

    // MARK: - Starting

    /// Lists the picked folders, checks space, and starts downloading.
    func start(_ picked: [GoogleDrive.File], client: GoogleDriveClient, availableSpace: Int64?) async {
        if !(job?.isActive ?? false) { clearFinished() }
        problem = nil
        isPreparing = true
        preparedCount = 0
        defer { isPreparing = false }

        var items: [DownloadItem] = []
        do {
            for file in picked {
                if file.isFolder {
                    try await collect(file, into: Self.safeName(file.name), client: client, items: &items)
                } else if Self.isImportable(file.name), !items.contains(where: { $0.id == file.id }) {
                    items.append(item(for: file, at: DownloadJob.looseFilesFolder + "/" + Self.safeName(file.name)))
                }
            }
        } catch {
            problem = Self.describe(error)
            return
        }
        // Files already in this job are not downloaded twice.
        let known = Set(job?.items.map(\.id) ?? [])
        items.removeAll { known.contains($0.id) }
        guard !items.isEmpty else {
            if known.isEmpty { problem = "No audio files in what you picked." }
            return
        }

        // The download and the verified copy both need room before the downloaded files go.
        let needed = items.reduce(Int64(0)) { $0 + $1.size }
        if let free = availableSpace, needed * 2 + FileImporter.spaceReserve > free {
            let short = needed * 2 + FileImporter.spaceReserve - free
            problem = "Not enough space on this iPhone. Free up \(ByteCountFormatter.string(fromByteCount: short, countStyle: .file)) and try again."
            return
        }

        if job == nil {
            job = DownloadJob(items: items)
            importedAudioCount = 0
            meter.reset()
        } else {
            job?.items += items
        }
        save(force: true)
        print("[Closure][Drive] queued \(items.count) file(s), \(needed) bytes")
        await pump()
    }

    private func item(for file: GoogleDrive.File, at path: String) -> DownloadItem {
        DownloadItem(id: file.id, name: file.name, size: file.byteCount, relativePath: path)
    }

    /// Lists a folder recursively. A listing that times out is tried again.
    private func collect(_ folder: GoogleDrive.File, into path: String, client: GoogleDriveClient, items: inout [DownloadItem]) async throws {
        let children = try await Self.withRetries { try await client.list(.folder(id: folder.id, name: folder.name)) }
        for child in children {
            let childPath = path + "/" + Self.safeName(child.name)
            if child.isFolder {
                try await collect(child, into: childPath, client: client, items: &items)
            } else if Self.isImportable(child.name), !items.contains(where: { $0.id == child.id }) {
                items.append(item(for: child, at: childPath))
                preparedCount = items.count
            }
        }
    }

    private static func withRetries<T>(_ body: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch {
                let code = (error as? URLError)?.code.rawValue
                guard attempt < 3, RetryPolicy.isTransient(urlErrorCode: code, httpStatus: nil) else { throw error }
                try await Task.sleep(for: .seconds(RetryPolicy.delay(afterAttempt: attempt)))
                attempt += 1
            }
        }
    }

    // MARK: - User actions

    func retry(_ id: String) async {
        guard job?.items.first(where: { $0.id == id })?.isFailed == true else { return }
        job?.update(id) {
            $0.state = .queued
            $0.attempts = 0
        }
        problem = nil
        save(force: true)
        await pump()
    }

    func retryAll() async {
        guard var job else { return }
        for index in job.items.indices where job.items[index].isFailed {
            job.items[index].state = .queued
            job.items[index].attempts = 0
        }
        self.job = job
        problem = nil
        save(force: true)
        await pump()
    }

    /// Stops what is left. Files already downloaded are still imported.
    func cancelRemaining() async {
        guard var job else { return }
        for (_, timer) in retryTimers { timer.cancel() }
        retryTimers.removeAll()
        retryAt.removeAll()
        for index in job.items.indices where job.items[index].state == .queued || job.items[index].state == .downloading
            || job.items[index].isFailed {
            tasks[job.items[index].id]?.cancel()
            tasks[job.items[index].id] = nil
            resumeData[job.items[index].id] = nil
            job.items[index].state = .failed("Cancelled")
        }
        self.job = job
        save(force: true)
        await finishIfDone()
    }

    /// Tries the import step again, e.g. after space was freed.
    func importAgain() async {
        problem = nil
        await finishIfDone()
    }

    /// Removes a finished job (and anything left of it on disk).
    func clearFinished() {
        guard let job, !job.isActive, !isImportingFiles else { return }
        self.job = nil
        problem = nil
        bytesPerSecond = 0
        try? FileManager.default.removeItem(at: filesRoot)
        try? FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: jobURL)
    }

    func dismissProblem() { problem = nil }

    // MARK: - App state

    /// In the background the system takes over: every file left is handed to it at once.
    func setBackground(_ background: Bool) async {
        inBackground = background
        await pump()
        save(force: true)
    }

    // MARK: - Scheduling

    /// Starts queued files up to the limit; imports when nothing is left.
    private func pump() async {
        guard let job, !isDemo else { return }
        let limit = inBackground ? Int.max : foregroundLimit
        var running = job.items.filter { $0.state == .downloading }.count
        for item in job.items where item.state == .queued && retryAt[item.id] == nil {
            guard running < limit else { break }
            running += 1
            await begin(item.id)
        }
        startTicker()
        await finishIfDone()
    }

    /// Keeps the speed current when no bytes arrive (a stall reads as zero).
    private func startTicker() {
        guard ticker == nil, job?.isActive == true else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.job?.isActive == true else { break }
                self.updateSpeed()
            }
            self?.ticker = nil
            self?.bytesPerSecond = 0
        }
    }

    private func begin(_ id: String) async {
        guard let item = job?.items.first(where: { $0.id == id }) else { return }
        let resume = resumeData.removeValue(forKey: id)
        job?.update(id) {
            $0.state = .downloading
            $0.attempts += 1
            if resume == nil { $0.received = 0 }
        }
        let task: URLSessionDownloadTask
        if let data = resume {
            task = session.downloadTask(withResumeData: data)
        } else {
            let token: String
            do {
                token = try await accessToken()
            } catch {
                fail(id, Self.describe(error), retryable: false)
                return
            }
            // The token wait can overlap a cancel; check the item still wants this.
            guard job?.items.first(where: { $0.id == id })?.state == .downloading else { return }
            var request = URLRequest(url: Self.mediaURL(for: item.id))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            task = session.downloadTask(with: request)
        }
        task.taskDescription = id
        if item.size > 0 { task.countOfBytesClientExpectsToReceive = item.size }
        tasks[id] = task
        task.resume()
    }

    static func mediaURL(for id: String) -> URL {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        components.queryItems = [.init(name: "alt", value: "media"), .init(name: "supportsAllDrives", value: "true")]
        return components.url!
    }

    // MARK: - Task results (main actor)

    fileprivate func progress(_ id: String, received: Int64) {
        guard job?.items.first(where: { $0.id == id })?.state == .downloading else { return }
        job?.update(id) { $0.received = received }
        updateSpeed()
        save(force: false)
    }

    fileprivate func finished(_ id: String, file: URL?, status: Int, error: URLError?, resume: Data?) async {
        tasks[id] = nil
        guard let item = job?.items.first(where: { $0.id == id }), item.state == .downloading else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        if let error {
            if let resume { resumeData[id] = resume }
            let transient = RetryPolicy.isTransient(urlErrorCode: error.code.rawValue, httpStatus: nil)
            fail(id, Self.describe(error), retryable: transient)
        } else if status == 200, let file {
            let destination = filesRoot.appendingPathComponent(item.relativePath)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: file, to: destination)
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? item.size
                job?.update(id) {
                    $0.state = .done
                    $0.received = size
                }
            } catch {
                fail(id, "Could not save the file.", retryable: false)
            }
        } else {
            if let file { try? FileManager.default.removeItem(at: file) }
            if status == 401, item.attempts < RetryPolicy.maxAttempts {
                // The token expired while the file waited. A fresh request gets a new one.
                job?.update(id) { $0.state = .queued }
            } else if status == 401 {
                fail(id, "Sign in to Google Drive again.", retryable: false)
            } else {
                fail(id, Self.describe(status: status), retryable: RetryPolicy.isTransient(urlErrorCode: nil, httpStatus: status))
            }
        }
        updateSpeed()
        save(force: true)
        await pump()
    }

    /// Marks a file failed; transient failures are retried after a growing delay.
    private func fail(_ id: String, _ message: String, retryable: Bool) {
        guard let attempts = job?.items.first(where: { $0.id == id })?.attempts else { return }
        print("[Closure][Drive] \(id) attempt \(attempts) failed: \(message)")
        if retryable, attempts < RetryPolicy.maxAttempts {
            let delay = retryDelay(attempts)
            job?.update(id) { $0.state = .queued }
            retryAt[id] = Date().addingTimeInterval(delay)
            retryTimers[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.retryAt[id] = nil
                self.retryTimers[id] = nil
                await self.pump()
            }
        } else {
            resumeData[id] = nil
            job?.update(id) { $0.state = .failed(message) }
        }
    }

    private func updateSpeed() {
        guard let job else { return }
        meter.record(totalBytes: job.receivedBytes, at: Date())
        bytesPerSecond = job.isActive ? meter.bytesPerSecond : 0
    }

    // MARK: - Import

    /// Imports downloaded files once nothing is queued or downloading.
    private func finishIfDone() async {
        guard let current = job, !current.isActive, !isImportingFiles, retryAt.isEmpty else { return }
        let ready = current.readyToImport
        guard !ready.isEmpty, let importFiles else { return }
        isImportingFiles = true
        let report = await importFiles(DownloadJob.importSources(for: ready, in: filesRoot))
        isImportingFiles = false
        if let shortfall = report.spaceShortfall, shortfall > 0 {
            // Nothing was copied. Keep the files and let the user try again.
            problem = "Not enough space to add the files. Free up \(ByteCountFormatter.string(fromByteCount: shortfall, countStyle: .file)) and try again."
            return
        }
        importedAudioCount += report.audioFiles
        if !report.failed.isEmpty {
            problem = "\(report.failed.count) file\(report.failed.count == 1 ? "" : "s") could not be added to the library."
        }
        // The importer made verified copies; the downloaded files are no longer needed.
        for item in ready {
            try? FileManager.default.removeItem(at: filesRoot.appendingPathComponent(item.relativePath))
            job?.update(item.id) { $0.state = .imported }
        }
        bytesPerSecond = 0
        save(force: true)
        if job?.failedCount == 0 {
            try? FileManager.default.removeItem(at: jobURL)
            try? FileManager.default.removeItem(at: filesRoot)
            try? FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        }
        print("[Closure][Drive] imported \(report.audioFiles) audio file(s); \(job?.failedCount ?? 0) failed download(s)")
    }

    // MARK: - Saving

    private func save(force: Bool) {
        guard force || Date().timeIntervalSince(lastSave) > 2 else { return }
        lastSave = Date()
        guard let job else { return }
        if let data = try? JSONEncoder().encode(job) { try? data.write(to: jobURL, options: .atomic) }
    }

    /// Reloads a saved job and reattaches to downloads still running in the session.
    private func restore() {
        guard let data = try? Data(contentsOf: jobURL), var saved = try? JSONDecoder().decode(DownloadJob.self, from: data) else { return }
        // Until the session reports its tasks, assume nothing is running.
        for index in saved.items.indices where saved.items[index].state == .downloading {
            saved.items[index].state = .queued
        }
        job = saved
        session.getAllTasks { [weak self] running in
            let pairs = running.compactMap { task -> (String, URLSessionDownloadTask)? in
                guard let id = task.taskDescription, let download = task as? URLSessionDownloadTask,
                      task.state == .running || task.state == .suspended else { return nil }
                return (id, download)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (id, task) in pairs {
                    self.tasks[id] = task
                    self.job?.update(id) {
                        $0.state = .downloading
                        $0.received = task.countOfBytesReceived
                    }
                }
                await self.pump()
            }
        }
    }

    /// Tests only: stop the session so it releases its delegate.
    func invalidate() {
        session.invalidateAndCancel()
        ticker?.cancel()
        for (_, timer) in retryTimers { timer.cancel() }
    }

    // MARK: - Names and messages

    static func isImportable(_ name: String) -> Bool {
        let kind = FileImporter.kind(of: URL(fileURLWithPath: name))
        return kind == .audio || kind == .companion
    }

    /// Drive names may contain "/" or be empty; local file names may not.
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "\u{2215}").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Untitled" : cleaned
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "The connection timed out."
            case .notConnectedToInternet: return "No internet connection."
            case .networkConnectionLost: return "The connection was lost."
            default: return error.localizedDescription
            }
        }
        if let error = error as? GoogleDrive.DriveError, error == .signInExpired {
            return "Sign in to Google Drive again."
        }
        return error.localizedDescription
    }

    static func describe(status: Int) -> String {
        switch status {
        case 403: return "Google Drive refused the download (HTTP 403)."
        case 404: return "The file is no longer in Google Drive."
        case 429: return "Google Drive is busy (HTTP 429)."
        default: return "Google Drive answered HTTP \(status)."
        }
    }
}

// MARK: - URLSession delegate (session queue)

extension DriveDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let now = Date()
        let due = progressGate.withLock { last in
            if let previous = last[id], now.timeIntervalSince(previous) < 0.25 { return false }
            last[id] = now
            return true
        }
        guard due else { return }
        Task { @MainActor in self.progress(id, received: totalBytesWritten) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // The file at `location` is removed when this returns; move it aside first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("drive-\(UUID().uuidString)")
        let moved = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        Task { @MainActor in await self.finished(id, file: moved ? kept : nil, status: status, error: nil, resume: nil) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return } // success was handled above
        let urlError = (error as? URLError) ?? URLError(.unknown)
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in await self.finished(id, file: nil, status: 0, error: urlError, resume: resume) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.save(force: true)
            Self.backgroundEventsDone?()
            Self.backgroundEventsDone = nil
        }
    }
}

#if DEBUG
extension DriveDownloadManager {
    /// -ClosureDownloadsDemo: a job in every state, for checking the Downloads page.
    /// Nothing is downloaded.
    static func loadDemoIfRequested(_ manager: DriveDownloadManager) {
        guard ProcessInfo.processInfo.arguments.contains("-ClosureDownloadsDemo") else { return }
        manager.isDemo = true
        let mb: Int64 = 1_048_576
        func item(_ id: String, _ path: String, _ size: Int64, _ state: DownloadItem.State, _ received: Int64 = 0, attempts: Int = 1) -> DownloadItem {
            DownloadItem(id: id, name: String(path.split(separator: "/").last!), size: size * mb / 10, relativePath: path,
                         state: state, received: received * mb / 10, attempts: attempts)
        }
        manager.job = DownloadJob(items: [
            item("1", "Low Light (Deluxe Edition)/CD1/01 Arrival.flac", 312, .imported),
            item("2", "Low Light (Deluxe Edition)/CD1/02 Night Drive.flac", 346, .done),
            item("3", "Low Light (Deluxe Edition)/CD1/03 Paper Moon.flac", 401, .downloading, 262),
            item("4", "Low Light (Deluxe Edition)/CD1/04 Still Water.flac", 288, .downloading, 41),
            item("5", "Low Light (Deluxe Edition)/CD2/01 Arrival (Demo).flac", 297, .queued, attempts: 2),
            item("6", "Low Light (Deluxe Edition)/CD2/02 Blue Hour.flac", 335, .queued, attempts: 0),
            item("7", "Low Light (Deluxe Edition)/cover.jpg", 12, .failed("The connection timed out."), attempts: 5),
            item("8", "files/Demo take.wav", 482, .queued, attempts: 0),
        ])
        manager.retryAt["5"] = Date().addingTimeInterval(8)
        manager.bytesPerSecond = 2.4 * Double(mb)
    }
}
#endif
