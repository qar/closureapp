import Foundation

/// What the user changed about an album, kept in the database. The files and their
/// tags are never changed; removing the override brings the original back.
struct AlbumOverride: Equatable, Sendable {
    /// The album's grouping key from its tags. It stays the album's identity when the
    /// title or artist is edited, so the album never splits or disappears.
    var albumKey: String
    var title: String?
    var artist: String?
    var year: Int?
    /// File name of the chosen cover in `AlbumOverrides.coversFolder`.
    var artworkFile: String?

    var isEmpty: Bool { title == nil && artist == nil && year == nil && artworkFile == nil }
}

enum AlbumOverrides {
    /// Covers the user picked. Kept with the library data, not in Caches.
    static var coversFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library/Covers", isDirectory: true)
    }

    /// Albums with the user's changes on top. Tracks get the new album title, year and
    /// (where they named the old album artist) the new artist, so Now Playing and
    /// search agree with the album page. Re-sorted, as the grid sorts by artist.
    static func apply(_ overrides: [String: AlbumOverride], to albums: [Album], coversFolder: URL = coversFolder) -> [Album] {
        guard !overrides.isEmpty else { return albums }
        let changed = albums.map { album -> Album in
            guard let override = overrides[album.id], !override.isEmpty else { return album }
            let cover = override.artworkFile.map { coversFolder.appendingPathComponent($0) }
            let tracks = album.tracks.map { track -> Track in
                var track = track
                track.originalAlbumKey = album.id
                if let title = override.title { track.album = title }
                if let year = override.year { track.year = year }
                if let artist = override.artist, track.artist == album.artist || track.artist.isEmpty { track.artist = artist }
                track.artworkOverride = cover
                return track
            }
            var result = Album(id: album.id, title: override.title ?? album.title, artist: override.artist ?? album.artist, tracks: tracks)
            result.yearOverride = override.year
            result.artworkOverride = cover
            result.original = Album.Original(title: album.title, artist: album.artist, year: album.year)
            return result
        }
        return changed.sorted { first, second in
            let byArtist = first.artist.localizedStandardCompare(second.artist)
            if byArtist != .orderedSame { return byArtist == .orderedAscending }
            return first.title.localizedStandardCompare(second.title) == .orderedAscending
        }
    }
}
