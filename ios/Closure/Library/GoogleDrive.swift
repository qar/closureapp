import CryptoKit
import Foundation
import Security

/// Google Drive access for importing music.
///
/// Main path: the user signs in once with the `drive.readonly` scope (restricted; usable
/// by test users while the Google project is in Testing, Google review needed before
/// release) and browses Drive inside the app. Fallback kept for a rejected review: the
/// `drive.file` scope with Google's picker for mobile apps (`pickerURL`).
/// iOS OAuth clients have no client secret; PKCE protects every code exchange.
enum GoogleDrive {
    static let readonlyScope = "https://www.googleapis.com/auth/drive.readonly"
    static let fileScope = "https://www.googleapis.com/auth/drive.file"
    static let folderMimeType = "application/vnd.google-apps.folder"
    static let shortcutMimeType = "application/vnd.google-apps.shortcut"

    struct Config: Equatable {
        let clientID: String
        let callbackScheme: String
        var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

        /// Read from Info.plist, which gets the values from GoogleOAuth.xcconfig.
        static func fromBundle(_ bundle: Bundle = .main) -> Config? {
            guard let clientID = bundle.object(forInfoDictionaryKey: "GoogleClientID") as? String,
                  let scheme = bundle.object(forInfoDictionaryKey: "GoogleCallbackScheme") as? String,
                  clientID.hasSuffix(".apps.googleusercontent.com"), !scheme.isEmpty else { return nil }
            return Config(clientID: clientID, callbackScheme: scheme)
        }
    }

    // MARK: - PKCE

    struct PKCE {
        let verifier: String
        var challenge: String { Self.challenge(for: verifier) }

        static func random() -> PKCE {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return PKCE(verifier: base64URL(Data(bytes)))
        }

        static func challenge(for verifier: String) -> String {
            base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    // MARK: - Authorization URLs and callback

    /// Sign-in for in-app browsing: read-only access to the whole Drive, with a refresh token.
    static func signInURL(config: Config, pkce: PKCE, state: String) -> URL {
        authorizationURL(config: config, pkce: pkce, state: state, scope: readonlyScope, extra: [])
    }

    /// Fallback: Google's picker for mobile apps with the non-restricted drive.file scope.
    static func pickerURL(config: Config, pkce: PKCE, state: String) -> URL {
        authorizationURL(config: config, pkce: pkce, state: state, scope: fileScope, extra: [
            .init(name: "trigger_onepick", value: "true"),
            .init(name: "allow_multiple", value: "true"),
            .init(name: "allow_folder_selection", value: "true"),
        ])
    }

    private static func authorizationURL(config: Config, pkce: PKCE, state: String, scope: String, extra: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ] + extra
        return components.url!
    }

    struct PickerResult: Equatable {
        let code: String
        let pickedIDs: [String]
    }

    enum DriveError: LocalizedError, Equatable {
        case notConfigured
        case cancelled
        case denied(String)
        case stateMismatch
        case noRefreshToken
        case signInExpired
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Google Drive is not set up in this build."
            case .cancelled: return "Cancelled."
            case let .denied(reason): return "Google did not grant access (\(reason))."
            case .stateMismatch: return "The sign-in response did not match this request."
            case .noRefreshToken: return "Google did not keep you signed in. Please sign in again."
            case .signInExpired: return "Your Google sign-in has expired. Please sign in again."
            case let .badResponse(detail): return "Google Drive returned an unexpected response: \(detail)"
            }
        }
    }

    static func parseCallback(_ url: URL, expectedState: String) throws -> PickerResult {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw error == "access_denied" ? DriveError.cancelled : DriveError.denied(error) }
        guard value("state") == expectedState else { throw DriveError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw DriveError.badResponse("no code") }
        let ids = (value("picked_file_ids") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return PickerResult(code: code, pickedIDs: ids)
    }

    // MARK: - Drive API models

    struct File: Decodable, Equatable, Hashable, Identifiable {
        struct Shortcut: Decodable, Equatable, Hashable {
            let targetId: String
            let targetMimeType: String?
        }

        let id: String
        let name: String
        let mimeType: String
        let size: String?
        let shortcutDetails: Shortcut?
        /// Lowercase hex SHA-256 of the content. Drive omits it for some files (shortcuts,
        /// Google Docs).
        let sha256Checksum: String?

        init(id: String, name: String, mimeType: String, size: String? = nil, shortcutDetails: Shortcut? = nil,
             sha256Checksum: String? = nil) {
            self.id = id
            self.name = name
            self.mimeType = mimeType
            self.size = size
            self.shortcutDetails = shortcutDetails
            self.sha256Checksum = sha256Checksum
        }

        var isFolder: Bool { mimeType == GoogleDrive.folderMimeType }
        var byteCount: Int64 { Int64(size ?? "") ?? 0 }

        /// A shortcut stands for its target; anything else for itself.
        var resolved: File {
            guard mimeType == GoogleDrive.shortcutMimeType, let target = shortcutDetails else { return self }
            return File(id: target.targetId, name: name, mimeType: target.targetMimeType ?? "", size: nil)
        }

        /// Shown while browsing: folders and audio files.
        var isBrowsable: Bool {
            isFolder || FileImporter.kind(of: URL(fileURLWithPath: name)) == .audio
        }
    }

    struct FileList: Decodable, Equatable {
        let files: [File]
        let nextPageToken: String?
    }

    struct SharedDrive: Decodable, Equatable, Hashable {
        let id: String
        let name: String
    }

    struct DriveList: Decodable {
        let drives: [SharedDrive]
        let nextPageToken: String?
    }

    struct About: Decodable {
        struct User: Decodable {
            let emailAddress: String?
            let displayName: String?
        }
        let user: User
    }

    struct Token: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    /// Places to browse.
    enum Location: Hashable {
        case myDrive
        case sharedWithMe
        case sharedDrives
        case sharedDrive(id: String, name: String)
        case folder(id: String, name: String)

        var title: String {
            switch self {
            case .myDrive: return "My Drive"
            case .sharedWithMe: return "Shared with me"
            case .sharedDrives: return "Shared drives"
            case let .sharedDrive(_, name), let .folder(_, name): return name
            }
        }
    }

    /// files.list parameters for a location. Folders first, natural name order.
    static func listQuery(for location: Location) -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            .init(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,shortcutDetails,sha256Checksum)"),
            .init(name: "orderBy", value: "folder,name_natural"),
            .init(name: "pageSize", value: "1000"),
            .init(name: "supportsAllDrives", value: "true"),
        ]
        switch location {
        case .myDrive:
            items.append(.init(name: "q", value: "'root' in parents and trashed = false"))
        case .sharedWithMe:
            items.append(.init(name: "q", value: "sharedWithMe = true and trashed = false"))
        case let .sharedDrive(id, _):
            items += [.init(name: "q", value: "'\(id)' in parents and trashed = false"),
                      .init(name: "corpora", value: "drive"), .init(name: "driveId", value: id),
                      .init(name: "includeItemsFromAllDrives", value: "true")]
        case let .folder(id, _):
            items += [.init(name: "q", value: "'\(id)' in parents and trashed = false"),
                      .init(name: "corpora", value: "allDrives"),
                      .init(name: "includeItemsFromAllDrives", value: "true")]
        case .sharedDrives:
            break
        }
        return items
    }
}

// MARK: - Client

/// Drive API calls. Every request asks `accessToken` for a current token, so the account
/// can refresh it transparently.
final class GoogleDriveClient {
    private let session: URLSession
    private let accessToken: () async throws -> String

    init(session: URLSession = .shared, accessToken: @escaping () async throws -> String) {
        self.session = session
        self.accessToken = accessToken
    }

    func about() async throws -> GoogleDrive.About {
        try await decode(apiRequest(path: "about", query: [.init(name: "fields", value: "user(emailAddress,displayName)")]))
    }

    /// Contents of a location, every page, shortcuts resolved.
    func list(_ location: GoogleDrive.Location) async throws -> [GoogleDrive.File] {
        if case .sharedDrives = location {
            return try await sharedDrives().map { GoogleDrive.File(id: $0.id, name: $0.name, mimeType: GoogleDrive.folderMimeType) }
        }
        var files: [GoogleDrive.File] = []
        var pageToken: String?
        repeat {
            var query = GoogleDrive.listQuery(for: location)
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            let page: GoogleDrive.FileList = try await decode(apiRequest(path: "files", query: query))
            files += page.files.map(\.resolved)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return files
    }

    func sharedDrives() async throws -> [GoogleDrive.SharedDrive] {
        var drives: [GoogleDrive.SharedDrive] = []
        var pageToken: String?
        repeat {
            var query: [URLQueryItem] = [.init(name: "pageSize", value: "100")]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            let page: GoogleDrive.DriveList = try await decode(apiRequest(path: "drives", query: query))
            drives += page.drives
            pageToken = page.nextPageToken
        } while pageToken != nil
        return drives
    }

    /// Downloads one file to `destination` (the parent folder must exist).
    func download(_ file: GoogleDrive.File, to destination: URL) async throws {
        let request = try await apiRequest(path: "files/\(file.id)", query: [.init(name: "alt", value: "media"),
                                                                             .init(name: "supportsAllDrives", value: "true")])
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoogleDrive.DriveError.badResponse("download \(file.name): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func apiRequest(path: String, query: [URLQueryItem]) async throws -> URLRequest {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GoogleDrive.DriveError.badResponse("HTTP \(status) \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GoogleDrive.DriveError.badResponse("cannot decode \(T.self)")
        }
    }
}

// MARK: - Tokens

/// OAuth token endpoint calls. No client secret: iOS clients use PKCE.
enum GoogleOAuth {
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    static func exchange(code: String, pkce: GoogleDrive.PKCE, config: GoogleDrive.Config, session: URLSession = .shared) async throws -> GoogleDrive.Token {
        try await post([
            .init(name: "code", value: code),
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code_verifier", value: pkce.verifier),
        ], session: session)
    }

    /// A 400 "invalid_grant" means the refresh token is no longer valid (revoked, or the
    /// 7-day limit for apps in Testing).
    static func refresh(_ refreshToken: String, config: GoogleDrive.Config, session: URLSession = .shared) async throws -> GoogleDrive.Token {
        do {
            return try await post([
                .init(name: "client_id", value: config.clientID),
                .init(name: "grant_type", value: "refresh_token"),
                .init(name: "refresh_token", value: refreshToken),
            ], session: session)
        } catch GoogleDrive.DriveError.badResponse(let detail) where detail.contains("invalid_grant") {
            throw GoogleDrive.DriveError.signInExpired
        }
    }

    static func revoke(_ token: String, session: URLSession = .shared) async {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(token)".data(using: .utf8)
        _ = try? await session.data(for: request)
    }

    private static func post(_ form: [URLQueryItem], session: URLSession) async throws -> GoogleDrive.Token {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GoogleDrive.DriveError.badResponse("HTTP \(status) \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        guard let token = try? JSONDecoder().decode(GoogleDrive.Token.self, from: data) else {
            throw GoogleDrive.DriveError.badResponse("cannot decode token")
        }
        return token
    }
}

/// Keychain storage for the refresh token and the signed-in email. Device-only items,
/// readable after first unlock (needed while importing in the background).
enum GoogleDriveKeychain {
    private static let service = "com.qar.closure.google-drive"

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
