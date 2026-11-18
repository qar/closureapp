import XCTest

final class GoogleDriveTests: XCTestCase {
    private let config = GoogleDrive.Config(clientID: "123-abc.apps.googleusercontent.com",
                                            callbackScheme: "com.googleusercontent.apps.123-abc")

    func testPKCEMatchesRFC7636Example() {
        // RFC 7636, appendix B.
        XCTAssertEqual(GoogleDrive.PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomVerifierIsURLSafeAndLongEnough() {
        let verifier = GoogleDrive.PKCE.random().verifier
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertNil(verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testPickerURLAsksForDriveFileWithThePicker() throws {
        let url = GoogleDrive.pickerURL(config: config, pkce: GoogleDrive.PKCE(verifier: "v"), state: "s1")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(query["scope"], "https://www.googleapis.com/auth/drive.file", "only drive.file")
        XCTAssertEqual(query["trigger_onepick"], "true")
        XCTAssertEqual(query["prompt"], "consent")
        XCTAssertEqual(query["allow_multiple"], "true")
        XCTAssertEqual(query["allow_folder_selection"], "true")
        XCTAssertEqual(query["redirect_uri"], "com.googleusercontent.apps.123-abc:/oauth2redirect")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["code_challenge"], GoogleDrive.PKCE.challenge(for: "v"))
        XCTAssertEqual(query["state"], "s1")
        XCTAssertNil(query["client_secret"])
    }

    func testCallbackWithPickedFiles() throws {
        let url = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=s1&code=4/xyz&picked_file_ids=a1,b2&scope=x")!
        XCTAssertEqual(try GoogleDrive.parseCallback(url, expectedState: "s1"),
                       GoogleDrive.PickerResult(code: "4/xyz", pickedIDs: ["a1", "b2"]))
    }

    func testCallbackErrors() {
        let cancelled = URL(string: "x:/oauth2redirect?error=access_denied&state=s1")!
        XCTAssertThrowsError(try GoogleDrive.parseCallback(cancelled, expectedState: "s1")) {
            XCTAssertEqual($0 as? GoogleDrive.DriveError, .cancelled)
        }
        let forged = URL(string: "x:/oauth2redirect?code=c&state=other")!
        XCTAssertThrowsError(try GoogleDrive.parseCallback(forged, expectedState: "s1")) {
            XCTAssertEqual($0 as? GoogleDrive.DriveError, .stateMismatch)
        }
    }

    func testFileListDecoding() throws {
        let json = """
        {"nextPageToken": "p2", "files": [
          {"id": "f1", "name": "CD1", "mimeType": "application/vnd.google-apps.folder"},
          {"id": "f2", "name": "01 Song.flac", "mimeType": "audio/flac", "size": "31457280"}
        ]}
        """
        let list = try JSONDecoder().decode(GoogleDrive.FileList.self, from: Data(json.utf8))
        XCTAssertEqual(list.nextPageToken, "p2")
        XCTAssertTrue(list.files[0].isFolder)
        XCTAssertFalse(list.files[1].isFolder)
        XCTAssertEqual(list.files[1].byteCount, 31_457_280)
        XCTAssertEqual(list.files[0].byteCount, 0)
    }
}

/// Answers URLSession requests from a closure, so Drive calls run without a network.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.handler?(request) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class GoogleDriveBrowsingTests: XCTestCase {
    private let config = GoogleDrive.Config(clientID: "123-abc.apps.googleusercontent.com",
                                            callbackScheme: "com.googleusercontent.apps.123-abc")

    override func setUp() {
        MockURLProtocol.handler = nil
        MockURLProtocol.requests = []
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    func testSignInURLAsksForReadOnlyDriveWithoutThePicker() throws {
        let url = GoogleDrive.signInURL(config: config, pkce: GoogleDrive.PKCE(verifier: "v"), state: "s")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["scope"], "https://www.googleapis.com/auth/drive.readonly")
        XCTAssertEqual(query["access_type"], "offline", "needed for a refresh token")
        XCTAssertEqual(query["prompt"], "consent")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertNil(query["trigger_onepick"])
        XCTAssertNil(query["client_secret"])
    }

    func testListQueries() {
        func q(_ location: GoogleDrive.Location) -> [String: String] {
            Dictionary(GoogleDrive.listQuery(for: location).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        }
        XCTAssertEqual(q(.myDrive)["q"], "'root' in parents and trashed = false")
        XCTAssertEqual(q(.sharedWithMe)["q"], "sharedWithMe = true and trashed = false")
        XCTAssertEqual(q(.sharedDrive(id: "D1", name: "Team"))["corpora"], "drive")
        XCTAssertEqual(q(.sharedDrive(id: "D1", name: "Team"))["driveId"], "D1")
        XCTAssertEqual(q(.folder(id: "F1", name: "Music"))["q"], "'F1' in parents and trashed = false")
        XCTAssertEqual(q(.folder(id: "F1", name: "Music"))["includeItemsFromAllDrives"], "true")
        XCTAssertEqual(q(.myDrive)["orderBy"], "folder,name_natural")
    }

    func testShortcutsResolveAndOnlyFoldersAndAudioAreBrowsable() {
        let shortcut = GoogleDrive.File(id: "s", name: "Albums", mimeType: GoogleDrive.shortcutMimeType,
                                        shortcutDetails: .init(targetId: "real", targetMimeType: GoogleDrive.folderMimeType))
        XCTAssertEqual(shortcut.resolved.id, "real")
        XCTAssertTrue(shortcut.resolved.isFolder)
        XCTAssertTrue(GoogleDrive.File(id: "1", name: "01.flac", mimeType: "audio/flac").isBrowsable)
        XCTAssertFalse(GoogleDrive.File(id: "2", name: "notes.pdf", mimeType: "application/pdf").isBrowsable)
    }

    func testListFollowsPagesSendsTheTokenAndResolvesShortcuts() async throws {
        MockURLProtocol.handler = { request in
            if self.query(request)["pageToken"] == "p2" {
                return (200, #"{"files":[{"id":"s1","name":"Link","mimeType":"application/vnd.google-apps.shortcut","shortcutDetails":{"targetId":"F9","targetMimeType":"application/vnd.google-apps.folder"}}]}"#)
            }
            return (200, #"{"nextPageToken":"p2","files":[{"id":"a","name":"01.flac","mimeType":"audio/flac","size":"42"}]}"#)
        }
        let client = GoogleDriveClient(session: MockURLProtocol.session()) { "TOKEN" }

        let files = try await client.list(.folder(id: "F1", name: "Music"))

        XCTAssertEqual(files.map(\.id), ["a", "F9"])
        XCTAssertTrue(files[1].isFolder)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        XCTAssertEqual(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer TOKEN")
    }

    func testSharedDrivesAreListedAsFolders() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/drive/v3/drives")
            return (200, #"{"drives":[{"id":"D1","name":"Band"}]}"#)
        }
        let client = GoogleDriveClient(session: MockURLProtocol.session()) { "T" }
        let files = try await client.list(.sharedDrives)
        XCTAssertEqual(files, [GoogleDrive.File(id: "D1", name: "Band", mimeType: GoogleDrive.folderMimeType)])
    }

    func testRefreshSucceeds() async throws {
        MockURLProtocol.handler = { _ in (200, #"{"access_token":"new","expires_in":3599}"#) }
        let token = try await GoogleOAuth.refresh("r", config: config, session: MockURLProtocol.session())
        XCTAssertEqual(token.access_token, "new")
        XCTAssertEqual(MockURLProtocol.requests.first?.url, GoogleOAuth.tokenURL)
    }

    func testExpiredRefreshTokenMeansSignInAgain() async {
        MockURLProtocol.handler = { _ in (400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#) }
        do {
            _ = try await GoogleOAuth.refresh("r", config: config, session: MockURLProtocol.session())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GoogleDrive.DriveError, .signInExpired)
        }
    }

    func testAPIErrorsAreReported() async {
        MockURLProtocol.handler = { _ in (403, #"{"error":{"code":403,"message":"insufficientPermissions"}}"#) }
        let client = GoogleDriveClient(session: MockURLProtocol.session()) { "T" }
        do {
            _ = try await client.list(.myDrive)
            XCTFail("expected an error")
        } catch let GoogleDrive.DriveError.badResponse(detail) {
            XCTAssertTrue(detail.contains("403"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
