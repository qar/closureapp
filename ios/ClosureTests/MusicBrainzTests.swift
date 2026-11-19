import XCTest

final class MusicBrainzTests: XCTestCase {
    func testQueryQuotesAndEscapes() {
        XCTAssertEqual(MusicBrainz.query(title: "Born To Die (The Paradise Edition)", artist: "Lana Del Rey"),
                       #"release:"Born To Die \(The Paradise Edition\)" AND artist:"Lana Del Rey""#)
        XCTAssertEqual(MusicBrainz.query(title: "AC/DC: Live", artist: "Various Artists"), #"release:"AC\/DC\: Live""#,
                       "a placeholder artist is left out")
    }

    func testDecodesAReleaseAndRanksByScoreThenTrackCount() throws {
        let json = #"""
        {"releases":[
          {"id":"a","title":"Born to Die","score":100,"date":"2012-01-27","country":"GB","track-count":12,
           "artist-credit":[{"name":"Lana Del Rey","joinphrase":""}],"media":[{"format":"CD","track-count":12}],
           "release-group":{"id":"g1","primary-type":"Album"}},
          {"id":"b","title":"Born to Die – The Paradise Edition","score":100,"date":"2012-11-09","track-count":15,
           "artist-credit":[{"name":"Lana Del Rey"}],"media":[{"format":"CD","track-count":15},{"format":"CD","track-count":8}],
           "release-group":{"id":"g2"}},
          {"id":"c","title":"Born to Die","score":90,"track-count":15}
        ]}
        """#
        let releases = try JSONDecoder().decode(MusicBrainz.SearchResult.self, from: Data(json.utf8)).releases
        XCTAssertEqual(releases[0].artist, "Lana Del Rey")
        XCTAssertEqual(releases[0].year, 2012)
        XCTAssertEqual(releases[0].format, "CD")
        XCTAssertEqual(releases[1].format, "2×CD")
        XCTAssertEqual(releases[1].coverURLs.map(\.absoluteString),
                       ["https://coverartarchive.org/release/b/front-1200", "https://coverartarchive.org/release-group/g2/front-1200"])
        XCTAssertEqual(MusicBrainz.ranked(releases, trackCount: 15).map(\.id), ["b", "a", "c"],
                       "equal scores: the release with the album's track count first")
    }

    func testSearchSendsTheUserAgentAndWaitsBetweenRequests() async throws {
        MockURLProtocol.handler = { _ in (200, #"{"releases":[]}"#) }
        MockURLProtocol.requests = []
        let client = MusicBrainzClient(session: MockURLProtocol.session())
        let started = Date()
        _ = try await client.search(title: "A", artist: "B", trackCount: 1)
        _ = try await client.search(title: "A", artist: "B", trackCount: 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.95, "one request a second")
        XCTAssertEqual(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "User-Agent"), MusicBrainz.userAgent)
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.host, "musicbrainz.org")
    }
}

final class MusicBrainzRetryTests: XCTestCase {
    func testABusyServerIsAskedAgain() async throws {
        var calls = 0
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in
            calls += 1
            return calls == 1 ? (503, "") : (200, #"{"releases":[{"id":"x","title":"T"}]}"#)
        }
        let client = MusicBrainzClient(session: MockURLProtocol.session())
        let releases = try await client.search(title: "T", artist: "", trackCount: 1, retryDelay: 0.1)
        XCTAssertEqual(releases.map(\.id), ["x"])
        XCTAssertEqual(calls, 2)
    }
}
