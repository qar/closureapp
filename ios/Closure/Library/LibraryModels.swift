import Foundation

enum LibraryPaths {
    /// The library folder. Files keep the layout they were imported with.
    static let musicFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Music", isDirectory: true)
    }()
}

struct Track: Identifiable, Hashable, Codable {
    /// Path relative to the library folder. The app container moves between installs
    /// and updates, so absolute paths are never stored.
    let id: String
    var title: String
    var artist: String
    var album: String
    /// 0 when unknown.
    var trackNumber: Int
    var duration: Double
    var codec: String
    var sampleRate: Double
    var bitDepth: Int
    var fileSize: Int64
    var modified: Date
    var year: Int?
    var albumArtist: String?
    var discNumber: Int?
    var composer: String?
    var genre: String?
    var isCompilation: Bool?

    var url: URL { LibraryPaths.musicFolder.appendingPathComponent(id) }

    /// Folder of the file, relative to the library root.
    var folder: String { id.split(separator: "/").dropLast().joined(separator: "/") }

    /// The folder that holds the album: "Box Set/CD2" counts as "Box Set".
    var albumFolder: String {
        let parts = id.split(separator: "/").dropLast()
        if let last = parts.last, LibraryGrouping.discNumber(fromFolderName: String(last)) != nil {
            return parts.dropLast().joined(separator: "/")
        }
        return parts.joined(separator: "/")
    }

    /// Tracks with the same key form one album. With an album artist tag the key is
    /// "album artist + album", so discs in separate folders and compilations stay
    /// together. Without it, the key is "album folder + album".
    var albumKey: String {
        let albumName = album.trimmingCharacters(in: .whitespaces).lowercased()
        if let albumArtist = albumArtist?.trimmingCharacters(in: .whitespaces), !albumArtist.isEmpty {
            return "artist\u{1F}\(albumArtist.lowercased())\u{1F}\(albumName)"
        }
        return "folder\u{1F}\(albumFolder)\u{1F}\(albumName)"
    }

    var formatSummary: String {
        var parts = [codec]
        if bitDepth > 0 { parts.append("\(bitDepth)-bit") }
        if sampleRate > 0 { parts.append(String(format: "%g kHz", sampleRate / 1000)) }
        return parts.joined(separator: " · ")
    }

    /// "FLAC 24/96", "ALAC 16/44.1", "AAC 44.1".
    var shortFormat: String {
        let rate = sampleRate > 0 ? String(format: "%g", sampleRate / 1000) : ""
        if bitDepth > 0 && !rate.isEmpty { return "\(codec) \(bitDepth)/\(rate)" }
        return rate.isEmpty ? codec : "\(codec) \(rate)"
    }

    var artworkRequest: ArtworkStore.Request {
        ArtworkStore.Request(key: albumKey, directory: url.deletingLastPathComponent(),
                             sampleTracks: [url], stamp: modified.timeIntervalSince1970)
    }
}

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]

    var folder: String { tracks.first?.folder ?? "" }
    var year: Int? { tracks.compactMap(\.year).min() }
    var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
    var discs: [Int] { Array(Set(tracks.map { $0.discNumber ?? 1 })).sorted() }

    /// The shared format, or "Mixed" when tracks differ.
    var format: String {
        let formats = Set(tracks.map(\.shortFormat))
        return formats.count == 1 ? formats.first! : "Mixed"
    }

    var artworkRequest: ArtworkStore.Request {
        ArtworkStore.Request(key: id, directory: tracks.first?.url.deletingLastPathComponent() ?? LibraryPaths.musicFolder,
                             sampleTracks: tracks.prefix(2).map(\.url),
                             stamp: tracks.first?.modified.timeIntervalSince1970 ?? 0)
    }
}

/// Shown once after an import that changed something.
struct ImportSummary: Identifiable {
    let id = UUID()
    let source: String
    let report: FileImporter.Report
}

// MARK: - Tags

/// One metadata item as AVFoundation reports it, e.g. "vorb/DISCNUMBER" = "2/3".
struct TagItem {
    var identifier: String
    var commonKey: String?
    var string: String?
    var number: Int?
    var data: Data?
}

struct ParsedTags: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var composer: String?
    var genre: String?
    var isCompilation: Bool?
}

/// Maps the identifiers of Vorbis comments (FLAC), iTunes atoms (M4A) and ID3 frames
/// (MP3) to one set of fields. Identifiers were checked against what AVFoundation
/// reports for files written by ffmpeg.
enum TagParser {
    private static let albumArtistIDs: Set<String> = ["vorb/ALBUMARTIST", "vorb/ALBUM ARTIST", "vorb/ALBUM_ARTIST", "itsk/aART", "id3/TPE2"]
    private static let trackIDs: Set<String> = ["vorb/TRACKNUMBER", "itsk/trkn", "id3/TRCK"]
    private static let discIDs: Set<String> = ["vorb/DISCNUMBER", "itsk/disk", "id3/TPOS"]
    private static let yearIDs: Set<String> = ["vorb/DATE", "vorb/YEAR", "vorb/ORIGINALDATE", "itsk/%A9day", "id3/TDRC", "id3/TYER", "id3/TDOR"]
    private static let composerIDs: Set<String> = ["vorb/COMPOSER", "itsk/%A9wrt", "id3/TCOM"]
    private static let genreIDs: Set<String> = ["vorb/GENRE", "itsk/%A9gen", "id3/TCON"]
    private static let compilationIDs: Set<String> = ["vorb/COMPILATION", "itsk/cpil", "id3/TCMP"]

    static func parse(_ items: [TagItem]) -> ParsedTags {
        var tags = ParsedTags()
        func text(_ item: TagItem) -> String? {
            guard let value = item.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        for item in items {
            switch item.commonKey {
            case "title": tags.title = tags.title ?? text(item)
            case "artist": tags.artist = tags.artist ?? text(item)
            case "albumName": tags.album = tags.album ?? text(item)
            case "creationDate": tags.year = tags.year ?? text(item).flatMap(year)
            default: break
            }
            let id = item.identifier
            if albumArtistIDs.contains(id) { tags.albumArtist = tags.albumArtist ?? text(item) }
            if trackIDs.contains(id) { tags.trackNumber = tags.trackNumber ?? number(item) }
            if discIDs.contains(id) { tags.discNumber = tags.discNumber ?? number(item) }
            if yearIDs.contains(id) { tags.year = tags.year ?? text(item).flatMap(year) }
            if composerIDs.contains(id) { tags.composer = tags.composer ?? text(item) }
            if genreIDs.contains(id) { tags.genre = tags.genre ?? text(item) }
            if compilationIDs.contains(id) { tags.isCompilation = tags.isCompilation ?? flag(item) }
        }
        return tags
    }

    /// "5/12" → 5, "05" → 5, iTunes trkn/disk data → the first 16-bit number.
    static func number(_ item: TagItem) -> Int? {
        if let string = item.string, let value = Int(string.split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? ""), value > 0 {
            return value
        }
        if let number = item.number, number > 0 { return number }
        if let data = item.data, data.count >= 4 {
            let bytes = [UInt8](data)
            let value = Int(bytes[2]) << 8 | Int(bytes[3])
            return value > 0 ? value : nil
        }
        return nil
    }

    static func flag(_ item: TagItem) -> Bool? {
        if let string = item.string?.lowercased() { return ["1", "true", "yes"].contains(string) }
        if let number = item.number { return number != 0 }
        if let data = item.data, let first = data.first { return first != 0 }
        return nil
    }

    /// First four-digit year in "2024", "2024-05-01" or "2024-05-01T00:00:00Z".
    static func year(from string: String) -> Int? {
        guard let range = string.range(of: #"\d{4}"#, options: .regularExpression),
              let value = Int(string[range]), (1000...2999).contains(value) else { return nil }
        return value
    }
}

// MARK: - Grouping

enum LibraryGrouping {
    /// Groups tracks into albums and sorts them by artist, then title.
    static func albums(from tracks: [Track]) -> [Album] {
        Dictionary(grouping: tracks, by: \.albumKey)
            .map { key, tracks in
                let sorted = tracks.sorted(by: trackOrder)
                return Album(id: key, title: sorted.first?.album ?? "Unknown Album",
                             artist: albumArtist(of: sorted), tracks: sorted)
            }
            .sorted { first, second in
                let byArtist = first.artist.localizedStandardCompare(second.artist)
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                return first.title.localizedStandardCompare(second.title) == .orderedAscending
            }
    }

    /// Disc, then track number (unknown numbers last), then file path.
    static func trackOrder(_ first: Track, _ second: Track) -> Bool {
        let discs = (first.discNumber ?? 1, second.discNumber ?? 1)
        if discs.0 != discs.1 { return discs.0 < discs.1 }
        let numbers = (first.trackNumber > 0 ? first.trackNumber : Int.max,
                       second.trackNumber > 0 ? second.trackNumber : Int.max)
        if numbers.0 != numbers.1 { return numbers.0 < numbers.1 }
        return first.id.localizedStandardCompare(second.id) == .orderedAscending
    }

    static func albumArtist(of tracks: [Track]) -> String {
        if let tagged = tracks.lazy.compactMap({ $0.albumArtist?.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return tagged
        }
        let artists = Set(tracks.map(\.artist).filter { !$0.isEmpty })
        if artists.count == 1, tracks.contains(where: { $0.isCompilation == true }) == false { return artists.first! }
        return artists.isEmpty ? "Unknown Artist" : "Various Artists"
    }

    /// "CD1", "CD 2", "Disc 3", "disk-4" → the number. Other names → nil.
    static func discNumber(fromFolderName name: String) -> Int? {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard let match = lowered.range(of: #"^(cd|disc|disk)[\s_\-]*(\d{1,2})$"#, options: .regularExpression) else { return nil }
        let digits = lowered[match].filter(\.isNumber)
        return Int(digits)
    }
}
