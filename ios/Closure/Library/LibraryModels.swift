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
    /// Set when an album override applies: the album's key from the tags, kept while
    /// the displayed album title changes. Never stored.
    var originalAlbumKey: String? = nil
    /// User-chosen album membership. Loaded from the database, never written to audio.
    var groupingKeyOverride: String? = nil
    /// The user's cover for this track's album, when there is one. Never stored.
    var artworkOverride: URL? = nil

    var url: URL { LibraryPaths.musicFolder.appendingPathComponent(id) }

    /// Folder of the file, relative to the library root.
    var folder: String { id.split(separator: "/").dropLast().joined(separator: "/") }

    /// Tracks with the same key form one album. File location does not determine
    /// album membership; a user assignment takes precedence over the tags.
    var albumKey: String { originalAlbumKey ?? groupingKeyOverride ?? tagAlbumKey }

    private var tagAlbumKey: String {
        let albumName = album.trimmingCharacters(in: .whitespaces).lowercased()
        if let albumArtist = albumArtist?.trimmingCharacters(in: .whitespaces), !albumArtist.isEmpty {
            return "artist\u{1F}\(albumArtist.lowercased())\u{1F}\(albumName)"
        }
        if isCompilation == true { return "compilation\u{1F}\(albumName)" }
        return "trackArtist\u{1F}\(artist.trimmingCharacters(in: .whitespaces).lowercased())\u{1F}\(albumName)"
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
        ArtworkStore.Request(key: albumKey + (artworkOverride.map { "|" + $0.lastPathComponent } ?? ""),
                             directory: url.deletingLastPathComponent(),
                             sampleTracks: [url], stamp: modified.timeIntervalSince1970, override: artworkOverride)
    }
}

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]
    /// Set by an album override.
    var yearOverride: Int? = nil
    var artworkOverride: URL? = nil
    /// What the tags said, when the user changed the title, artist or year.
    var original: Original? = nil

    struct Original: Hashable {
        var title: String
        var artist: String
        var year: Int?
    }

    var isEdited: Bool { original != nil }

    var folder: String { tracks.first?.folder ?? "" }
    var year: Int? { yearOverride ?? tracks.compactMap(\.year).min() }
    var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
    var discs: [Int] { Array(Set(tracks.map { $0.discNumber ?? 1 })).sorted() }

    /// The shared format, or "Mixed" when tracks differ.
    var format: String {
        let formats = Set(tracks.map(\.shortFormat))
        return formats.count == 1 ? formats.first! : "Mixed"
    }

    var artworkRequest: ArtworkStore.Request {
        ArtworkStore.Request(key: id + (artworkOverride.map { "|" + $0.lastPathComponent } ?? ""),
                             directory: tracks.first?.url.deletingLastPathComponent() ?? LibraryPaths.musicFolder,
                             sampleTracks: tracks.prefix(2).map(\.url),
                             stamp: tracks.first?.modified.timeIntervalSince1970 ?? 0, override: artworkOverride)
    }
}

struct LibrarySnapshot {
    var albums: [Album]
    var unassignedTracks: [Track]
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

/// Maps Vorbis comments, iTunes atoms, ID3 frames, ID3v1 and APEv2 items to one
/// set of fields. AVFoundation identifiers were checked against ffmpeg-written files.
enum TagParser {
    private static let albumArtistIDs: Set<String> = ["vorb/ALBUMARTIST", "vorb/ALBUM ARTIST", "vorb/ALBUM_ARTIST", "itsk/aART", "id3/TPE2", "ape/ALBUM ARTIST", "ape/ALBUMARTIST"]
    private static let trackIDs: Set<String> = ["vorb/TRACKNUMBER", "itsk/trkn", "id3/TRCK", "id3v1/TRACK", "ape/TRACK"]
    private static let discIDs: Set<String> = ["vorb/DISCNUMBER", "itsk/disk", "id3/TPOS", "ape/DISC"]
    private static let yearIDs: Set<String> = ["vorb/DATE", "vorb/YEAR", "vorb/ORIGINALDATE", "itsk/%A9day", "id3/TDRC", "id3/TYER", "id3/TDOR", "ape/YEAR", "ape/DATE"]
    private static let composerIDs: Set<String> = ["vorb/COMPOSER", "itsk/%A9wrt", "id3/TCOM", "ape/COMPOSER"]
    private static let genreIDs: Set<String> = ["vorb/GENRE", "itsk/%A9gen", "id3/TCON", "id3v1/GENRE", "ape/GENRE"]
    private static let compilationIDs: Set<String> = ["vorb/COMPILATION", "itsk/cpil", "id3/TCMP", "ape/COMPILATION"]

    static func parse(_ items: [TagItem]) -> ParsedTags {
        var tags = ParsedTags()
        func text(_ item: TagItem) -> String? {
            guard var value = item.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            // ID3 text declared as Latin-1 often holds GBK or Big5 bytes.
            if item.identifier.hasPrefix("id3/") { value = TagTextRepair.repairCJK(value) }
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

/// Repairs Chinese text that was decoded as Latin-1.
///
/// Many Chinese MP3s store GBK or Big5 bytes in ID3 frames marked ISO-8859-1, so
/// "周杰伦" arrives as "ÖÜ½ÜÂ×". The text is turned back into bytes and decoded as
/// GB18030 or Big5, but only when all of these hold:
/// - every character is U+00FF or below, so the bytes can be recovered;
/// - every byte of 0x80 or above starts a double-byte pair (lead 0x81–0xFE,
///   trail 0x40–0x7E or 0x80–0xFE);
/// - fewer than half of the pairs look like Latin text, i.e. an accented letter
///   (0xC0 and above) followed by a lowercase ASCII letter, as in "ör" or "ón";
/// - the decoded text contains Chinese characters, and every non-ASCII character
///   in it is Chinese or CJK punctuation.
/// Latin names such as "Björk", "Mötley Crüe" or "Corazón" are left unchanged.
enum TagTextRepair {
    static func repairCJK(_ text: String, preferTraditional: Bool = prefersTraditionalChinese) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0x80 }),
              text.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) else { return text }
        let bytes = text.unicodeScalars.map { UInt8($0.value) }

        var pairs = 0
        var latinLike = 0
        var index = 0
        while index < bytes.count {
            let lead = bytes[index]
            if lead < 0x80 { index += 1; continue }
            guard index + 1 < bytes.count, (0x81...0xFE).contains(lead) else { return text }
            let trail = bytes[index + 1]
            guard (0x40...0x7E).contains(trail) || (0x80...0xFE).contains(trail) else { return text }
            pairs += 1
            if lead >= 0xC0 && (0x61...0x7A).contains(trail) { latinLike += 1 }
            index += 2
        }
        guard pairs > 0, latinLike * 2 < pairs else { return text }

        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
        for encoding in preferTraditional ? [big5, gb] : [gb, big5] {
            guard let decoded = String(data: Data(bytes), encoding: encoding) else { continue }
            let nonASCII = decoded.unicodeScalars.filter { $0.value >= 0x80 }
            if nonASCII.contains(where: isCJKIdeograph), nonASCII.allSatisfy(isCJKText) {
                return decoded
            }
        }
        return text
    }

    private static func isCJKIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    /// Ideographs, CJK punctuation, fullwidth forms and general punctuation.
    private static func isCJKText(_ scalar: Unicode.Scalar) -> Bool {
        isCJKIdeograph(scalar)
            || (0x3000...0x303F).contains(scalar.value)
            || (0xFF00...0xFFEF).contains(scalar.value)
            || (0x2000...0x206F).contains(scalar.value)
    }

    static var prefersTraditionalChinese: Bool {
        guard let language = Locale.preferredLanguages.first?.lowercased() else { return false }
        return language.hasPrefix("zh-hant") || language.hasPrefix("zh-tw") || language.hasPrefix("zh-hk") || language.hasPrefix("zh-mo")
    }
}

// MARK: - Grouping

enum LibraryGrouping {
    static func snapshot(from tracks: [Track]) -> LibrarySnapshot {
        let unassigned = tracks.filter {
            $0.groupingKeyOverride == nil && $0.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return LibrarySnapshot(albums: albums(from: tracks), unassignedTracks: unassigned)
    }

    /// Groups tracks into albums and sorts them by artist, then title.
    static func albums(from tracks: [Track]) -> [Album] {
        let assigned = tracks.filter {
            $0.groupingKeyOverride != nil || !$0.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Dictionary(grouping: assigned, by: \.albumKey)
            .map { key, tracks in
                let sorted = tracks.sorted(by: trackOrder)
                let native = sorted.filter { $0.groupingKeyOverride == nil }
                let representative = native.first ?? sorted.first
                let name = representative?.album.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = name.isEmpty ? "Unknown Album" : name
                let displayed = sorted.map { track -> Track in
                    var track = track
                    if track.groupingKeyOverride != nil { track.album = title }
                    return track
                }
                return Album(id: key, title: title,
                             artist: albumArtist(of: native.isEmpty ? sorted : native), tracks: displayed)
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
