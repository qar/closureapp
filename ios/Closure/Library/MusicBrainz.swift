import Foundation

/// Album search on MusicBrainz, covers from the Cover Art Archive. Only runs when the
/// user asks; sends the album title and artist, nothing else.
///
/// MusicBrainz asks for at most one request per second and a User-Agent that names
/// the app and a contact: https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting
enum MusicBrainz {
    static let userAgent = "Closure/0.1 ( https://github.com/qar )"

    struct Release: Decodable, Identifiable, Equatable {
        let id: String
        let title: String
        let score: Int?
        let date: String?
        let country: String?
        let trackCount: Int?
        let artistCredit: [Credit]?
        let media: [Medium]?
        let releaseGroup: Group?

        struct Credit: Decodable, Equatable {
            let name: String
            let joinphrase: String?
        }

        struct Medium: Decodable, Equatable {
            let format: String?
            let trackCount: Int?

            enum CodingKeys: String, CodingKey {
                case format
                case trackCount = "track-count"
            }
        }

        struct Group: Decodable, Equatable {
            let id: String
            let primaryType: String?

            enum CodingKeys: String, CodingKey {
                case id
                case primaryType = "primary-type"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, title, score, date, country, media
            case trackCount = "track-count"
            case artistCredit = "artist-credit"
            case releaseGroup = "release-group"
        }

        var artist: String {
            (artistCredit ?? []).map { $0.name + ($0.joinphrase ?? "") }.joined()
        }

        var year: Int? { date.flatMap { Int($0.prefix(4)) } }

        /// "CD", "2×CD", "Digital Media".
        var format: String? {
            let formats = (media ?? []).compactMap(\.format)
            guard let first = formats.first else { return nil }
            return formats.allSatisfy({ $0 == first }) && formats.count > 1 ? "\(formats.count)×\(first)" : first
        }

        /// Small cover for the result list (release first; the release group often has one when the release does not).
        var thumbnailURL: URL { URL(string: "https://coverartarchive.org/release/\(id)/front-250")! }

        var coverURLs: [URL] {
            var urls = [URL(string: "https://coverartarchive.org/release/\(id)/front-1200")!]
            if let group = releaseGroup { urls.append(URL(string: "https://coverartarchive.org/release-group/\(group.id)/front-1200")!) }
            return urls
        }
    }

    struct SearchResult: Decodable {
        let releases: [Release]
    }

    /// Lucene query for a release title and artist. Quotes keep words together; the
    /// characters Lucene treats specially are escaped.
    static func query(title: String, artist: String) -> String {
        func quoted(_ text: String) -> String {
            let special = "\\+-&|!(){}[]^\"~*?:/"
            let escaped = text.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
            return "\"\(escaped)\""
        }
        var parts = ["release:\(quoted(title))"]
        let artist = artist.trimmingCharacters(in: .whitespaces)
        if !artist.isEmpty, artist != "Unknown Artist", artist != "Various Artists" {
            parts.append("artist:\(quoted(artist))")
        }
        return parts.joined(separator: " AND ")
    }

    static func searchURL(title: String, artist: String, limit: Int = 15) -> URL {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        components.queryItems = [.init(name: "query", value: query(title: title, artist: artist)),
                                 .init(name: "fmt", value: "json"), .init(name: "limit", value: "\(limit)")]
        return components.url!
    }

    /// Best matches first: MusicBrainz's score, then releases with the same number of
    /// tracks as the album, then dated releases before undated ones.
    static func ranked(_ releases: [Release], trackCount: Int) -> [Release] {
        releases.enumerated().sorted { a, b in
            let scoreA = a.element.score ?? 0, scoreB = b.element.score ?? 0
            if scoreA != scoreB { return scoreA > scoreB }
            let matchA = a.element.trackCount == trackCount, matchB = b.element.trackCount == trackCount
            if matchA != matchB { return matchA }
            if (a.element.year == nil) != (b.element.year == nil) { return a.element.year != nil }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// Sends MusicBrainz requests no faster than one a second.
actor MusicBrainzClient {
    private let session: URLSession
    private var lastRequest = Date.distantPast

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// A 503 means "too many requests from this address" (a shared network counts
    /// everyone); it is retried after the server's Retry-After, at most twice.
    func search(title: String, artist: String, trackCount: Int, retryDelay: TimeInterval = 2) async throws -> [MusicBrainz.Release] {
        var request = URLRequest(url: MusicBrainz.searchURL(title: title, artist: artist))
        request.setValue(MusicBrainz.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 1...3 {
            let wait = 1.0 - Date().timeIntervalSince(lastRequest)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            lastRequest = Date()
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 200 {
                let result = try JSONDecoder().decode(MusicBrainz.SearchResult.self, from: data)
                return MusicBrainz.ranked(result.releases, trackCount: trackCount)
            }
            print("[Closure][MusicBrainz] HTTP \(status) on attempt \(attempt)")
            guard status == 503, attempt < 3 else { break }
            let after = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? retryDelay * Double(attempt)
            try await Task.sleep(for: .seconds(min(10, max(1, after))))
        }
        throw URLError(.resourceUnavailable)
    }

    /// The large front cover of a release (or its release group). Nil when there is none.
    func cover(for release: MusicBrainz.Release) async -> Data? {
        for url in release.coverURLs {
            var request = URLRequest(url: url)
            request.setValue(MusicBrainz.userAgent, forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                return data
            }
        }
        return nil
    }
}
