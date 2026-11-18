import XCTest

final class DownloadJobTests: XCTestCase {
    private func item(_ id: String, _ path: String, size: Int64 = 100, state: DownloadItem.State = .queued, received: Int64 = 0) -> DownloadItem {
        DownloadItem(id: id, name: id, size: size, relativePath: path, state: state, received: received)
    }

    func testProgressCountsFinishedFilesAndPartialBytes() {
        let job = DownloadJob(items: [
            item("a", "Album/a.flac", state: .done),
            item("b", "Album/b.flac", state: .downloading, received: 40),
            item("c", "Album/c.flac", state: .failed("timed out")),
            item("d", "Album/d.flac"),
        ])
        XCTAssertEqual(job.totalBytes, 400)
        XCTAssertEqual(job.receivedBytes, 140)
        XCTAssertEqual(job.fraction, 0.35, accuracy: 0.0001)
        XCTAssertEqual(job.finishedCount, 1)
        XCTAssertEqual(job.failedCount, 1)
        XCTAssertEqual(job.activeCount, 2)
    }

    func testNothingIsImportedWhileFilesAreStillComing() {
        var job = DownloadJob(items: [item("a", "Album/a.flac", state: .done), item("b", "Album/b.flac", state: .downloading)])
        XCTAssertTrue(job.readyToImport.isEmpty, "the album should arrive in one piece")
        job.update("b") { $0.state = .failed("timed out") }
        XCTAssertEqual(job.readyToImport.map(\.id), ["a"], "failed files do not block the rest")
    }

    func testRetriedFilesAreImportedWithoutTheOnesAlreadyImported() {
        var job = DownloadJob(items: [item("a", "Album/a.flac", state: .imported), item("b", "Album/b.flac", state: .failed("x"))])
        job.update("b") { $0.state = .done }
        XCTAssertEqual(job.readyToImport.map(\.id), ["b"])
    }

    func testImportSources() {
        let root = URL(fileURLWithPath: "/tmp/job")
        let sources = DownloadJob.importSources(for: [
            item("a", "Low Light/CD1/01.flac"), item("b", "Low Light/CD2/01.flac"),
            item("c", "files/single.flac"), item("d", "Paper Rooms/01.m4a"),
        ], in: root)
        XCTAssertEqual(sources.map(\.path), ["/tmp/job/Low Light", "/tmp/job/Paper Rooms", "/tmp/job/files/single.flac"])
    }

    func testJobSurvivesEncoding() throws {
        let job = DownloadJob(items: [item("a", "A/a.flac", state: .failed("HTTP 500"), received: 12)])
        XCTAssertEqual(try JSONDecoder().decode(DownloadJob.self, from: JSONEncoder().encode(job)), job)
    }

    func testRetryPolicy() {
        XCTAssertTrue(RetryPolicy.isTransient(urlErrorCode: NSURLErrorTimedOut, httpStatus: nil))
        XCTAssertTrue(RetryPolicy.isTransient(urlErrorCode: NSURLErrorNetworkConnectionLost, httpStatus: nil))
        XCTAssertTrue(RetryPolicy.isTransient(urlErrorCode: nil, httpStatus: 503))
        XCTAssertTrue(RetryPolicy.isTransient(urlErrorCode: nil, httpStatus: 429))
        XCTAssertFalse(RetryPolicy.isTransient(urlErrorCode: nil, httpStatus: 404))
        XCTAssertFalse(RetryPolicy.isTransient(urlErrorCode: nil, httpStatus: 403))
        XCTAssertFalse(RetryPolicy.isTransient(urlErrorCode: NSURLErrorCancelled, httpStatus: nil))
        XCTAssertEqual(RetryPolicy.delay(afterAttempt: 1), 2)
        XCTAssertEqual(RetryPolicy.delay(afterAttempt: 3), 8)
        XCTAssertEqual(RetryPolicy.delay(afterAttempt: 10), 60)
    }

    func testSpeedMeterUsesARecentWindow() {
        var meter = SpeedMeter(window: 5)
        let start = Date()
        meter.record(totalBytes: 0, at: start)
        meter.record(totalBytes: 1_000_000, at: start.addingTimeInterval(1))
        meter.record(totalBytes: 2_000_000, at: start.addingTimeInterval(2))
        XCTAssertEqual(meter.bytesPerSecond, 1_000_000, accuracy: 1)
        meter.record(totalBytes: 2_000_000, at: start.addingTimeInterval(10))
        XCTAssertEqual(meter.bytesPerSecond, 0, "old samples drop out; a stall reads as zero")
    }
}
