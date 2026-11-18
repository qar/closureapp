import Foundation

/// User changes stored beside the library index. Nil means use the file's tag.
struct TrackOverride: Equatable, Sendable {
    var trackID: String
    var title: String? = nil
    var artist: String? = nil
    var album: String? = nil
    var albumArtist: String? = nil
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
    var year: Int? = nil
    var composer: String? = nil
    var genre: String? = nil
    /// A stable album identity for user-initiated merges and splits.
    var groupKey: String? = nil

    var isEmpty: Bool {
        title == nil && artist == nil && album == nil && albumArtist == nil &&
        trackNumber == nil && discNumber == nil && year == nil && composer == nil &&
        genre == nil && groupKey == nil
    }

    func apply(to source: Track) -> Track {
        var track = source
        if let title { track.title = title }
        if let artist { track.artist = artist }
        if let album { track.album = album }
        if let albumArtist { track.albumArtist = albumArtist }
        if let trackNumber { track.trackNumber = trackNumber }
        if let discNumber { track.discNumber = discNumber }
        if let year { track.year = year }
        if let composer { track.composer = composer }
        if let genre { track.genre = genre }
        track.groupingKeyOverride = groupKey
        return track
    }
}
