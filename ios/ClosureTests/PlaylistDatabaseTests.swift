import XCTest

final class PlaylistDatabaseTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("playlists-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    func testFavoritesExistAndCannotBeDeleted() throws {
        let database = try LibraryDatabase(url: url)
        XCTAssertEqual(try database.allPlaylists().map(\.id), [Playlist.favoritesID])
        try database.deletePlaylist(id: Playlist.favoritesID)
        XCTAssertEqual(try database.allPlaylists().map(\.id), [Playlist.favoritesID])
    }

    func testPlaylistsKeepOrderAndItems() throws {
        let database = try LibraryDatabase(url: url)
        try database.savePlaylist(Playlist(id: "b", name: "Road", trackIDs: ["x/1.flac", "x/2.flac"]), sortOrder: 1)
        try database.savePlaylist(Playlist(id: "a", name: "Night", trackIDs: ["y/1.flac"]), sortOrder: 2)
        try database.savePlaylist(Playlist(id: Playlist.favoritesID, name: "Favorites", trackIDs: ["z.flac"]), sortOrder: 0)
        var playlists = try database.allPlaylists()
        XCTAssertEqual(playlists.map(\.name), ["Favorites", "Road", "Night"])
        XCTAssertEqual(playlists[1].trackIDs, ["x/1.flac", "x/2.flac"])

        // Saving again replaces the items and keeps the place.
        try database.savePlaylist(Playlist(id: "b", name: "Road Trip", trackIDs: ["x/2.flac"]), sortOrder: 5)
        playlists = try database.allPlaylists()
        XCTAssertEqual(playlists.map(\.name), ["Favorites", "Road Trip", "Night"])
        XCTAssertEqual(playlists[1].trackIDs, ["x/2.flac"])

        try database.deletePlaylist(id: "a")
        XCTAssertEqual(try database.allPlaylists().map(\.id), [Playlist.favoritesID, "b"])
    }

    func testTracksInRecentlyDeletedAreSkippedNotLost() {
        let track = Track(id: "x/1.flac", title: "One", artist: "", album: "", trackNumber: 1, duration: 1, codec: "FLAC",
                          sampleRate: 44100, bitDepth: 16, fileSize: 1, modified: Date(), year: nil, albumArtist: nil,
                          discNumber: nil, composer: nil, genre: nil, isCompilation: nil)
        let playlist = Playlist(id: "p", name: "P", trackIDs: ["x/1.flac", "gone.flac"])
        XCTAssertEqual(playlist.tracks(in: ["x/1.flac": track]).map(\.id), ["x/1.flac"])
        XCTAssertEqual(playlist.trackIDs.count, 2)
    }
}
