import Foundation

/// A playlist: an ordered list of library tracks, by their library-relative paths.
/// Favorites is a built-in playlist that cannot be renamed or deleted.
struct Playlist: Identifiable, Equatable, Hashable, Sendable {
    static let favoritesID = "favorites"

    let id: String
    var name: String
    var trackIDs: [String]

    var isFavorites: Bool { id == Self.favoritesID }

    /// The tracks still in the library, in playlist order. Tracks in Recently Deleted
    /// are skipped and come back when restored.
    func tracks(in library: [String: Track]) -> [Track] {
        trackIDs.compactMap { library[$0] }
    }
}
