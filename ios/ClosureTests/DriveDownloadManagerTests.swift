import XCTest

/// Answers each request with an error or a status and body, per test.
final class DownloadMockProtocol: URLProtocol {
    enum Reply {
        case ok(Data)
        case status(Int)
        case fail(URLError.Code)
    }

    nonisolated(unsafe) static var reply: ((URLRequest) -> Reply)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.reply?(request) ?? .status(500)
        Self.lock.unlock()
        switch reply {
        case let .fail(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .ok(data):
            send(200, data)
        case let .status(status):
            send(status, Data("{\"error\":\(status)}".utf8))
        }
    }

    private func send(_ status: Int, _ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadMockProtocol.self]
        return configuration
    }

    static func mediaRequests(for id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.path == "/drive/v3/files/\(id)" && $0.url?.query?.contains("alt=media") == true }.count
    }
}

@MainActor
final class DriveDownloadManagerTests: XCTestCase {
    private var root: URL!
    private var managers: [DriveDownloadManager] = []
    private var imported: [[String]] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)")
        DownloadMockProtocol.reply = nil
        DownloadMockProtocol.requests = []
        imported = []
    }

    override func tearDown() async throws {
        for manager in managers { manager.invalidate() }
        managers = []
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager() -> DriveDownloadManager {
        let manager = DriveDownloadManager(root: root, configuration: DownloadMockProtocol.configuration()) { "token" }
        manager.retryDelay = { _ in 0.05 }
        manager.importFiles = { [unowned self] sources in
            // Record what would be imported, relative to the job folder.
            self.imported.append(sources.map { $0.path.replacingOccurrences(of: manager.filesRoot.path + "/", with: "") })
            var report = FileImporter.Report()
            report.audioFiles = sources.count
            return report
        }
        managers.append(manager)
        return manager
    }

    private var client: GoogleDriveClient {
        let session = URLSession(configuration: DownloadMockProtocol.configuration())
        return GoogleDriveClient(session: session) { "token" }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func audio(_ id: String, _ name: String, size: Int = 4) -> GoogleDrive.File {
        GoogleDrive.File(id: id, name: name, mimeType: "audio/flac", size: "\(size)")
    }

    func testTimeoutsAreRetriedUntilTheFileArrives() async {
        var calls = 0
        DownloadMockProtocol.reply = { _ in
            calls += 1
            return calls < 3 ? .fail(.timedOut) : .ok(Data("FLAC".utf8))
        }
        let manager = makeManager()
        await manager.start([audio("a", "01.flac")], client: client, availableSpace: nil)
        await waitUntil { manager.job?.items.first?.state == .imported }

        let item = manager.job?.items.first
        XCTAssertEqual(item?.state, .imported)
        XCTAssertEqual(item?.attempts, 3)
        XCTAssertEqual(imported, [["files/01.flac"]])
        XCTAssertEqual(manager.importedAudioCount, 1)
        XCTAssertNil(manager.problem)
    }

    func testAMissingFileFailsAtOnceAndTheRestStillImports() async {
        DownloadMockProtocol.reply = { request in
            request.url!.path.hasSuffix("/gone") ? .status(404) : .ok(Data("FLAC".utf8))
        }
        let manager = makeManager()
        await manager.start([audio("ok", "01.flac"), audio("gone", "02.flac")], client: client, availableSpace: nil)
        await waitUntil { manager.job?.isActive == false && !self.imported.isEmpty }

        XCTAssertEqual(manager.job?.items.first { $0.id == "gone" }?.state, .failed("The file is no longer in Google Drive."))
        XCTAssertEqual(DownloadMockProtocol.mediaRequests(for: "gone"), 1, "a 404 is not retried")
        XCTAssertEqual(manager.job?.items.first { $0.id == "ok" }?.state, .imported)
        XCTAssertEqual(manager.job?.failedCount, 1)
    }

    func testManualRetryOfAFailedFile() async {
        var broken = true
        DownloadMockProtocol.reply = { _ in broken ? .status(403) : .ok(Data("FLAC".utf8)) }
        let manager = makeManager()
        await manager.start([audio("a", "01.flac")], client: client, availableSpace: nil)
        await waitUntil { manager.job?.failedCount == 1 }
        XCTAssertEqual(manager.job?.failedCount, 1)

        broken = false
        await manager.retry("a")
        await waitUntil { manager.job?.items.first?.state == .imported }
        XCTAssertEqual(manager.job?.items.first?.state, .imported)
        XCTAssertEqual(manager.job?.items.first?.attempts, 1, "a manual retry starts the count again")
    }

    func testFoldersAreListedAndImportedAsOneAlbum() async throws {
        DownloadMockProtocol.reply = { request in
            let url = request.url!
            if url.path == "/drive/v3/files" {
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
                if q.contains("'album'") {
                    return .ok(Data(#"{"files":[{"id":"cd1","name":"CD1","mimeType":"application/vnd.google-apps.folder"},{"id":"cover","name":"cover.jpg","mimeType":"image/jpeg","size":"3"},{"id":"zip","name":"stems.zip","mimeType":"application/zip","size":"9"}]}"#.utf8))
                }
                return .ok(Data(#"{"files":[{"id":"t1","name":"01.flac","mimeType":"audio/flac","size":"4"},{"id":"t2","name":"02.flac","mimeType":"audio/flac","size":"4"}]}"#.utf8))
            }
            return .ok(Data("DATA".utf8))
        }
        let manager = makeManager()
        let folder = GoogleDrive.File(id: "album", name: "Low/Light", mimeType: GoogleDrive.folderMimeType)
        await manager.start([folder], client: client, availableSpace: nil)
        await waitUntil { manager.job?.isActive == false && !self.imported.isEmpty }

        let paths = manager.job?.items.map(\.relativePath).sorted()
        XCTAssertEqual(paths, ["Low\u{2215}Light/CD1/01.flac", "Low\u{2215}Light/CD1/02.flac", "Low\u{2215}Light/cover.jpg"])
        XCTAssertEqual(imported, [["Low\u{2215}Light"]], "the album folder is imported once, after every file arrived")
        XCTAssertEqual(DownloadMockProtocol.mediaRequests(for: "zip"), 0)
    }

    func testContentAlreadyInTheLibraryIsNotDownloaded() async {
        DownloadMockProtocol.reply = { _ in .ok(Data("FLAC".utf8)) }
        let manager = makeManager()
        var asked: [String] = []
        manager.filesAlreadyInLibrary = { files in
            asked = files.map(\.sha256)
            return Set(files.filter { $0.sha256 == "aa11" }.map(\.id))
        }
        let known = GoogleDrive.File(id: "k", name: "renamed.flac", mimeType: "audio/flac", size: "4", sha256Checksum: "AA11")
        let new = GoogleDrive.File(id: "n", name: "02.flac", mimeType: "audio/flac", size: "4", sha256Checksum: "bb22")
        await manager.start([known, new], client: client, availableSpace: nil)
        await waitUntil { manager.job?.isActive == false && !self.imported.isEmpty }

        XCTAssertEqual(asked.sorted(), ["aa11", "bb22"], "Drive's hex is compared in lowercase")
        XCTAssertEqual(manager.job?.items.first { $0.id == "k" }?.state, .alreadyInLibrary)
        XCTAssertEqual(DownloadMockProtocol.mediaRequests(for: "k"), 0)
        XCTAssertEqual(manager.job?.items.first { $0.id == "n" }?.state, .imported)
    }

    func testNotEnoughSpaceStartsNothing() async {
        DownloadMockProtocol.reply = { _ in .ok(Data("FLAC".utf8)) }
        let manager = makeManager()
        await manager.start([audio("a", "01.flac", size: 1_000_000)], client: client, availableSpace: 1_000)
        XCTAssertNil(manager.job)
        XCTAssertNotNil(manager.problem)
        XCTAssertEqual(DownloadMockProtocol.mediaRequests(for: "a"), 0)
    }

    func testASavedJobContinuesAfterRelaunch() async throws {
        // A job saved mid-download, with no task left in the session.
        let saved = DownloadJob(items: [
            DownloadItem(id: "a", name: "01.flac", size: 4, relativePath: "Album/01.flac", state: .downloading, received: 2, attempts: 1),
            DownloadItem(id: "b", name: "02.flac", size: 4, relativePath: "Album/02.flac", state: .queued),
        ])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: root.appendingPathComponent("job.json"))
        DownloadMockProtocol.reply = { _ in .ok(Data("FLAC".utf8)) }

        let manager = makeManager()
        await waitUntil { !self.imported.isEmpty }
        XCTAssertEqual(manager.job?.items.map(\.state), [.imported, .imported])
        XCTAssertEqual(imported, [["Album"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("job.json").path),
                       "a finished job leaves nothing behind")
    }

    func testOnlyThreeFilesDownloadAtOnceInTheForeground() async {
        DownloadMockProtocol.reply = { _ in .fail(.timedOut) }
        let manager = makeManager()
        manager.retryDelay = { _ in 60 }
        await manager.start((1...6).map { audio("f\($0)", "0\($0).flac") }, client: client, availableSpace: nil)
        XCTAssertEqual(manager.job?.items.filter { $0.state == .downloading }.count, 3)
        await manager.cancelRemaining()
        XCTAssertEqual(manager.job?.isActive, false)
    }
}
