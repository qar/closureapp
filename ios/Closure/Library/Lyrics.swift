import AVFoundation
import CryptoKit
import Foundation

/// Lyrics for one track: timed lines from LRC (".lrc" next to the audio file, or LRC
/// text in the tags), or plain lines when there are no times.
struct Lyrics: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        /// Seconds from the start; nil for plain lyrics.
        let time: Double?
        let text: String
    }

    let lines: [Line]

    var isSynced: Bool { lines.first?.time != nil }

    /// The line being sung at `time`: the last line that has started.
    func index(at time: Double) -> Int? {
        guard isSynced else { return nil }
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if (lines[middle].time ?? 0) <= time {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    // MARK: - LRC

    private static let stamp = try! NSRegularExpression(pattern: #"^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let wordStamp = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)
    private static let metadata = try! NSRegularExpression(pattern: #"^\[([a-zA-Z#]+):(.*)\]\s*$"#)

    /// Parses LRC ("[01:02.50]text", several stamps per line allowed, "[offset:…]"
    /// honoured, word stamps "<…>" dropped). Text without any stamp becomes plain
    /// lyrics. Nil when there is no text at all.
    static func parse(_ text: String) -> Lyrics? {
        var timed: [Line] = []
        var plain: [String] = []
        var offset = 0.0
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            let whole = NSRange(line.startIndex..., in: line)
            if let match = metadata.firstMatch(in: line, range: whole), stamp.firstMatch(in: line, range: whole) == nil {
                // [ar:…], [ti:…], [offset:+250] …
                let key = (line as NSString).substring(with: match.range(at: 1)).lowercased()
                if key == "offset", let value = Double((line as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)) {
                    offset = value / 1000
                }
                continue
            }
            var times: [Double] = []
            while let match = stamp.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let part = { (index: Int) -> String? in
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? nil : (line as NSString).substring(with: range)
                }
                let minutes = Double(part(1) ?? "0") ?? 0, seconds = Double(part(2) ?? "0") ?? 0
                var fraction = 0.0
                if let digits = part(3) { fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count)) }
                times.append(minutes * 60 + seconds + fraction)
                line = (line as NSString).replacingCharacters(in: match.range, with: "")
            }
            let words = wordStamp.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            if times.isEmpty {
                plain.append(words)
            } else if !words.isEmpty {
                // Positive offsets show the lyrics earlier.
                timed += times.map { Line(time: max(0, $0 - offset), text: words) }
            }
        }
        if !timed.isEmpty {
            return Lyrics(lines: timed.sorted { ($0.time ?? 0) < ($1.time ?? 0) })
        }
        // Plain lyrics: keep single blank lines between verses, drop the rest.
        var lines: [Line] = []
        for text in plain where !(text.isEmpty && (lines.last?.text.isEmpty ?? true)) {
            lines.append(Line(time: nil, text: text))
        }
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        return lines.isEmpty ? nil : Lyrics(lines: lines)
    }

    /// Text of a .lrc file: UTF-8 or UTF-16 (with a byte order mark), otherwise the
    /// GBK or Big5 that Chinese lyric files often use.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Read the bytes one to one, then let the tag repair pick GBK or Big5.
        guard let latin = String(data: data, encoding: .isoLatin1) else { return nil }
        return TagTextRepair.repairCJK(latin)
    }
}

/// Finds a track's lyrics: a ".lrc" file with the same name, then the tags, then lyrics
/// fetched from LRCLIB (kept in the app's data, never in the music folder).
enum LyricsLoader {
    private static let tagIDs: Set<String> = ["id3/USLT", "itsk/%A9lyr", "vorb/LYRICS", "vorb/UNSYNCEDLYRICS",
                                              "vorb/UNSYNCED LYRICS", "vorb/SYNCEDLYRICS"]

    static var fetchedFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library/Lyrics", isDirectory: true)
    }

    static func load(for track: Track, fetchedFolder: URL = fetchedFolder) async -> Lyrics? {
        if let lyrics = await loadFromFiles(track.url) { return lyrics }
        guard let data = try? Data(contentsOf: fetchedFile(for: track.id, in: fetchedFolder)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Lyrics.parse(ChineseScript.forReader(text))
    }

    /// Lyrics the user brought: the .lrc next to the file, or the tags.
    static func loadFromFiles(_ url: URL) async -> Lyrics? {
        if let file = sidecar(for: url), let data = try? Data(contentsOf: file),
           let text = Lyrics.decode(data), let lyrics = Lyrics.parse(text) {
            return lyrics
        }
        guard let items = try? await AVURLAsset(url: url).load(.metadata) else { return nil }
        for item in items where tagIDs.contains(item.identifier?.rawValue ?? "") {
            if var text = try? await item.load(.stringValue) {
                if item.identifier?.rawValue.hasPrefix("id3/") == true { text = TagTextRepair.repairCJK(text) }
                if let lyrics = Lyrics.parse(text) { return lyrics }
            }
        }
        return nil
    }

    static func fetchedFile(for trackID: String, in folder: URL = fetchedFolder) -> URL {
        let name = SHA256.hash(data: Data(trackID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + ".lrc")
    }

    static func saveFetched(_ text: String, for trackID: String, in folder: URL = fetchedFolder) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: fetchedFile(for: trackID, in: folder), options: .atomic)
    }

    /// "01 Song.lrc" (any case) next to "01 Song.flac".
    static func sidecar(for url: URL) -> URL? {
        let base = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension.lowercased() == "lrc" && $0.deletingPathExtension().lastPathComponent == base }
    }
}

/// Fetched lyrics are often in Traditional Chinese. A reader whose iPhone is set to
/// Simplified Chinese gets them in Simplified (the system's own conversion).
enum ChineseScript {
    static var prefersSimplified: Bool {
        guard let language = Locale.preferredLanguages.first else { return false }
        return language.hasPrefix("zh-Hans") || language == "zh-CN" || language == "zh-SG"
    }

    static func forReader(_ text: String, simplified: Bool = prefersSimplified) -> String {
        guard simplified else { return text }
        return text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }
}

/// Lyrics search on LRCLIB (lrclib.net): free, no key, synced lyrics when someone
/// added them. Runs only when the user asks; sends the track title, artist, album and
/// length.
enum LRCLIB {
    struct Record: Decodable, Equatable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?

        /// Synced lyrics when there are any, else plain.
        var text: String? {
            if let synced = syncedLyrics, !synced.isEmpty { return synced }
            if let plain = plainLyrics, !plain.isEmpty { return plain }
            return nil
        }
    }

    static func getURL(title: String, artist: String, album: String, duration: Double) -> URL {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist),
                                 .init(name: "album_name", value: album), .init(name: "duration", value: String(Int(duration.rounded())))]
        return components.url!
    }

    static func searchURL(title: String, artist: String) -> URL {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
        return components.url!
    }

    /// From search results: lyrics within 3 seconds of the track's length, synced first.
    static func best(_ records: [Record], duration: Double) -> Record? {
        let close = records.filter { record in
            record.text != nil && (duration <= 0 || abs((record.duration ?? 0) - duration) <= 3)
        }
        return close.first { $0.syncedLyrics?.isEmpty == false } ?? close.first
    }
}

/// Fetches lyrics from LRCLIB, one request at a time.
actor LyricsClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Lyrics text for one track, or nil.
    func lyrics(title: String, artist: String, album: String, duration: Double) async -> String? {
        if let record: LRCLIB.Record = await fetch(LRCLIB.getURL(title: title, artist: artist, album: album, duration: duration)),
           let text = record.text {
            return text
        }
        let records: [LRCLIB.Record]? = await fetch(LRCLIB.searchURL(title: title, artist: artist))
        return LRCLIB.best(records ?? [], duration: duration)?.text
    }

    /// Fetches lyrics for the tracks that have none yet and saves them. Returns how
    /// many tracks have lyrics afterwards. `progress` gets (done, total).
    func fillMissing(_ tracks: [Track], artist: String?, album: String?, progress: @Sendable (Int, Int) async -> Void) async -> (found: Int, total: Int) {
        var found = 0
        for (index, track) in tracks.enumerated() {
            await progress(index, tracks.count)
            if await LyricsLoader.load(for: track) != nil {
                found += 1
                continue
            }
            let trackArtist = track.artist.isEmpty ? (artist ?? "") : track.artist
            if let text = await lyrics(title: track.title, artist: trackArtist, album: album ?? track.album, duration: track.duration) {
                LyricsLoader.saveFetched(text, for: track.id)
                found += 1
            }
        }
        await progress(tracks.count, tracks.count)
        return (found, tracks.count)
    }

    private func fetch<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.setValue(MusicBrainz.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
