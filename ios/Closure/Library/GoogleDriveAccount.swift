import Foundation
import Observation

/// The signed-in Google account for Drive browsing. Keeps the refresh token in the
/// Keychain and a short-lived access token in memory, refreshed when it is about to
/// expire.
@MainActor
@Observable
final class GoogleDriveAccount {
    private(set) var email: String?
    private(set) var isSigningIn = false
    var isSignedIn: Bool { refreshToken != nil }
    var isConfigured: Bool { config != nil }

    @ObservationIgnored private let config = GoogleDrive.Config.fromBundle()
    @ObservationIgnored private var refreshToken: String?
    @ObservationIgnored private var accessToken: (value: String, expires: Date)?
    @ObservationIgnored private var refreshTask: Task<String, Error>?

    private static let refreshKey = "refresh-token"
    private static let emailKey = "email"

    init() {
        refreshToken = GoogleDriveKeychain.get(Self.refreshKey)
        email = GoogleDriveKeychain.get(Self.emailKey)
    }

    /// Opens Google sign-in for read-only Drive access. `authenticate` shows the URL in a
    /// browser session and returns the callback URL.
    func signIn(authenticate: (URL, String) async throws -> URL) async throws {
        guard let config else { throw GoogleDrive.DriveError.notConfigured }
        isSigningIn = true
        defer { isSigningIn = false }
        let pkce = GoogleDrive.PKCE.random()
        let state = UUID().uuidString
        let callback = try await authenticate(GoogleDrive.signInURL(config: config, pkce: pkce, state: state), config.callbackScheme)
        let result = try GoogleDrive.parseCallback(callback, expectedState: state)
        let token = try await GoogleOAuth.exchange(code: result.code, pkce: pkce, config: config)
        guard let refresh = token.refresh_token else { throw GoogleDrive.DriveError.noRefreshToken }
        refreshToken = refresh
        GoogleDriveKeychain.set(refresh, for: Self.refreshKey)
        accessToken = (token.access_token, Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600)))
        let about = try? await client().about()
        email = about?.user.emailAddress ?? about?.user.displayName
        GoogleDriveKeychain.set(email, for: Self.emailKey)
        print("[Closure][Drive] signed in as \(email ?? "?")")
    }

    /// Revokes the grant at Google and forgets it here.
    func signOut() async {
        if let refreshToken { await GoogleOAuth.revoke(refreshToken) }
        forget()
    }

    func client() -> GoogleDriveClient {
        GoogleDriveClient { [weak self] in
            guard let self else { throw GoogleDrive.DriveError.signInExpired }
            return try await self.validAccessToken()
        }
    }

    /// A token valid for at least another minute. Concurrent callers share one refresh.
    func validAccessToken() async throws -> String {
        if let accessToken, accessToken.expires.timeIntervalSinceNow > 60 { return accessToken.value }
        if let refreshTask { return try await refreshTask.value }
        guard let config, let refreshToken else { throw GoogleDrive.DriveError.signInExpired }
        // Runs on the main actor, like this class, so it can update the stored token.
        let task = Task { () throws -> String in
            do {
                let token = try await GoogleOAuth.refresh(refreshToken, config: config)
                self.accessToken = (token.access_token, Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600)))
                return token.access_token
            } catch GoogleDrive.DriveError.signInExpired {
                self.forget()
                throw GoogleDrive.DriveError.signInExpired
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func forget() {
        refreshToken = nil
        accessToken = nil
        email = nil
        GoogleDriveKeychain.set(nil, for: Self.refreshKey)
        GoogleDriveKeychain.set(nil, for: Self.emailKey)
    }
}
