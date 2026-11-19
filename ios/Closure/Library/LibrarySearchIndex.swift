import Foundation

/// Search keys are built once per library revision, off the UI thread.
struct LibrarySearchIndex: Sendable {
    struct AlbumDocument: Sendable {
        let id: String
        let title: String
        let artist: String
        let tracks: [TrackDocument]
    }

    struct TrackDocument: Sendable {
        let id: String
        let title: String
        let artist: String
        let composer: String?
    }

    struct AlbumHit: Sendable, Equatable {
        let index: Int
        let id: String
    }

    struct TrackHit: Sendable, Equatable {
        let albumIndex: Int?
        let trackIndex: Int
        let id: String
    }

    struct Results: Sendable, Equatable {
        var albums: [AlbumHit] = []
        var tracks: [TrackHit] = []
    }

    private struct Key: Sendable {
        let folded: String
        let romanized: String
        let initials: String

        init(_ text: String) {
            folded = Self.fold(text)
            guard !text.utf8.allSatisfy({ $0 < 128 }) else {
                romanized = ""
                initials = ""
                return
            }
            let latin = Self.fold(text.applyingTransform(.toLatin, reverse: false) ?? text)
            let words = latin.split { !$0.isLetter && !$0.isNumber }
            romanized = words.joined()
            initials = String(words.compactMap(\.first))
        }

        static func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                         locale: Locale(identifier: "en_US_POSIX"))
        }

        func matches(_ query: String, compact: String) -> Bool {
            folded.contains(query) || (!romanized.isEmpty && (romanized.contains(compact) || initials.contains(compact)))
        }
    }

    private struct AlbumEntry: Sendable {
        let hit: AlbumHit
        let keys: [Key]
    }

    private struct TrackEntry: Sendable {
        let hit: TrackHit
        let keys: [Key]
    }

    private let albums: [AlbumEntry]
    private let tracks: [TrackEntry]

    init(documents: [AlbumDocument], unassignedTracks: [TrackDocument] = []) {
        var cache: [String: Key] = [:]
        func key(_ text: String) -> Key {
            if let cached = cache[text] { return cached }
            let value = Key(text)
            cache[text] = value
            return value
        }

        var albumEntries: [AlbumEntry] = []
        var trackEntries: [TrackEntry] = []
        for (albumIndex, album) in documents.enumerated() {
            let albumTitle = key(album.title)
            albumEntries.append(AlbumEntry(hit: AlbumHit(index: albumIndex, id: album.id),
                                           keys: [albumTitle, key(album.artist)]))
            for (trackIndex, track) in album.tracks.enumerated() {
                var keys = [key(track.title), key(track.artist), albumTitle]
                if let composer = track.composer { keys.append(key(composer)) }
                trackEntries.append(TrackEntry(hit: TrackHit(albumIndex: albumIndex, trackIndex: trackIndex,
                                                              id: track.id), keys: keys))
            }
        }
        for (trackIndex, track) in unassignedTracks.enumerated() {
            var keys = [key(track.title), key(track.artist)]
            if let composer = track.composer { keys.append(key(composer)) }
            trackEntries.append(TrackEntry(hit: TrackHit(albumIndex: nil, trackIndex: trackIndex,
                                                          id: track.id), keys: keys))
        }
        albums = albumEntries
        tracks = trackEntries
    }

    func search(_ rawQuery: String) -> Results {
        let query = Key.fold(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return Results() }
        let compact = query.filter { !$0.isWhitespace }
        var results = Results()
        for album in albums where album.keys.contains(where: { $0.matches(query, compact: compact) }) {
            results.albums.append(album.hit)
            if results.albums.count == 20 { break }
        }
        for track in tracks where track.keys.contains(where: { $0.matches(query, compact: compact) }) {
            results.tracks.append(track.hit)
            if results.tracks.count == 50 { break }
        }
        return results
    }
}
