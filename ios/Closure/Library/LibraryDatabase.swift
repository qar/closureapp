import Foundation
import SQLite3

/// The library index in SQLite (the system library, so no install size).
///
/// One row per audio file, keyed by its path relative to the library folder. The
/// table is the source of truth for metadata; the files keep the layout they were
/// imported with. Not thread safe: one owner (LibraryCatalog) uses it at a time.
final class LibraryDatabase {
    static let schemaVersion = 4

    enum DatabaseError: Error, CustomStringConvertible {
        case sqlite(String)
        var description: String { if case let .sqlite(message) = self { return message }; return "" }
    }

    /// Size and modification time, used to decide whether a file must be read again.
    struct Stamp: Equatable {
        var size: Int64
        var modified: Double
    }

    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw DatabaseError.sqlite("cannot open \(url.lastPathComponent)")
        }
        try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        try migrate()
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    // MARK: - Reading

    func trackCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM tracks") { count = Int(sqlite3_column_int64($0, 0)) }
        return count
    }

    func allTracks() throws -> [Track] {
        var tracks: [Track] = []
        tracks.reserveCapacity(try trackCount())
        try query("SELECT \(Self.columns) FROM tracks") { tracks.append(Self.track(from: $0)) }
        return tracks
    }

    func stamps() throws -> [String: Stamp] {
        var stamps: [String: Stamp] = [:]
        try query("SELECT id, file_size, modified FROM tracks") { row in
            stamps[Self.text(row, 0) ?? ""] = Stamp(size: sqlite3_column_int64(row, 1), modified: sqlite3_column_double(row, 2))
        }
        return stamps
    }

    // MARK: - Writing

    /// Inserts or replaces tracks in one transaction.
    func upsert(_ tracks: [Track]) throws {
        guard !tracks.isEmpty else { return }
        try transaction {
            let statement = try prepare("INSERT OR REPLACE INTO tracks (\(Self.columns)) VALUES (\(Array(repeating: "?", count: 18).joined(separator: ", ")))")
            defer { sqlite3_finalize(statement) }
            for track in tracks {
                sqlite3_reset(statement)
                bind(statement, 1, track.id)
                bind(statement, 2, track.title)
                bind(statement, 3, track.artist)
                bind(statement, 4, track.album)
                bind(statement, 5, track.albumArtist)
                sqlite3_bind_int64(statement, 6, Int64(track.trackNumber))
                bind(statement, 7, track.discNumber)
                bind(statement, 8, track.year)
                bind(statement, 9, track.composer)
                bind(statement, 10, track.genre)
                bind(statement, 11, track.isCompilation.map { $0 ? 1 : 0 })
                sqlite3_bind_double(statement, 12, track.duration)
                bind(statement, 13, track.codec)
                sqlite3_bind_double(statement, 14, track.sampleRate)
                sqlite3_bind_int64(statement, 15, Int64(track.bitDepth))
                sqlite3_bind_int64(statement, 16, track.fileSize)
                sqlite3_bind_double(statement, 17, track.modified.timeIntervalSince1970)
                bind(statement, 18, track.albumKey)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            }
        }
    }

    func delete(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            let statement = try prepare("DELETE FROM tracks WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            for id in ids {
                sqlite3_reset(statement)
                bind(statement, 1, id)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            }
        }
    }

    // MARK: - Schema

    private static let columns = "id, title, artist, album, album_artist, track_number, disc_number, year, composer, genre, is_compilation, duration, codec, sample_rate, bit_depth, file_size, modified, album_key"

    private func migrate() throws {
        var version = 0
        try query("PRAGMA user_version") { version = Int(sqlite3_column_int($0, 0)) }
        if version < 1 {
            try execute("""
                CREATE TABLE IF NOT EXISTS tracks (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL, artist TEXT NOT NULL, album TEXT NOT NULL,
                    album_artist TEXT, track_number INTEGER NOT NULL, disc_number INTEGER, year INTEGER,
                    composer TEXT, genre TEXT, is_compilation INTEGER,
                    duration REAL NOT NULL, codec TEXT NOT NULL, sample_rate REAL NOT NULL, bit_depth INTEGER NOT NULL,
                    file_size INTEGER NOT NULL, modified REAL NOT NULL, album_key TEXT NOT NULL
                ) WITHOUT ROWID;
                CREATE INDEX IF NOT EXISTS tracks_album_key ON tracks(album_key);
                PRAGMA user_version = 1;
                """)
        }
        if version < 2 {
            // The user's album edits, keyed by the album's grouping key from its tags.
            try execute("""
                CREATE TABLE IF NOT EXISTS album_overrides (
                    album_key TEXT PRIMARY KEY NOT NULL,
                    title TEXT, artist TEXT, year INTEGER, artwork_file TEXT
                ) WITHOUT ROWID;
                PRAGMA user_version = 2;
                """)
        }
        if version < 3 {
            // Playlists, with Favorites built in. Items refer to tracks by path.
            try execute("""
                CREATE TABLE IF NOT EXISTS playlists (
                    id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, sort_order INTEGER NOT NULL
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS playlist_items (
                    playlist_id TEXT NOT NULL, position INTEGER NOT NULL, track_id TEXT NOT NULL,
                    PRIMARY KEY (playlist_id, position)
                ) WITHOUT ROWID;
                INSERT OR IGNORE INTO playlists (id, name, sort_order) VALUES ('favorites', 'Favorites', 0);
                PRAGMA user_version = 3;
                """)
        }
        if version < 4 {
            try execute("""
                CREATE TABLE IF NOT EXISTS track_overrides (
                    track_id TEXT PRIMARY KEY NOT NULL,
                    title TEXT, artist TEXT, album TEXT, album_artist TEXT,
                    track_number INTEGER, disc_number INTEGER, year INTEGER,
                    composer TEXT, genre TEXT, group_key TEXT
                ) WITHOUT ROWID;
                PRAGMA user_version = 4;
                """)
        }
    }

    // MARK: - Playlists

    /// Every playlist, Favorites first, then in the order they were made.
    func allPlaylists() throws -> [Playlist] {
        var playlists: [Playlist] = []
        try query("SELECT id, name FROM playlists ORDER BY sort_order, id") { row in
            playlists.append(Playlist(id: Self.text(row, 0) ?? "", name: Self.text(row, 1) ?? "", trackIDs: []))
        }
        var items: [String: [String]] = [:]
        try query("SELECT playlist_id, track_id FROM playlist_items ORDER BY playlist_id, position") { row in
            items[Self.text(row, 0) ?? "", default: []].append(Self.text(row, 1) ?? "")
        }
        return playlists.map { Playlist(id: $0.id, name: $0.name, trackIDs: items[$0.id] ?? []) }
    }

    /// Saves a playlist's name and items, replacing what was there.
    func savePlaylist(_ playlist: Playlist, sortOrder: Int) throws {
        try transaction {
            let upsert = try prepare("INSERT INTO playlists (id, name, sort_order) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name")
            defer { sqlite3_finalize(upsert) }
            bind(upsert, 1, playlist.id)
            bind(upsert, 2, playlist.name)
            sqlite3_bind_int64(upsert, 3, Int64(sortOrder))
            guard sqlite3_step(upsert) == SQLITE_DONE else { throw error() }

            let clear = try prepare("DELETE FROM playlist_items WHERE playlist_id = ?")
            defer { sqlite3_finalize(clear) }
            bind(clear, 1, playlist.id)
            guard sqlite3_step(clear) == SQLITE_DONE else { throw error() }

            let insert = try prepare("INSERT INTO playlist_items (playlist_id, position, track_id) VALUES (?, ?, ?)")
            defer { sqlite3_finalize(insert) }
            for (position, trackID) in playlist.trackIDs.enumerated() {
                sqlite3_reset(insert)
                bind(insert, 1, playlist.id)
                sqlite3_bind_int64(insert, 2, Int64(position))
                bind(insert, 3, trackID)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw error() }
            }
        }
    }

    func deletePlaylist(id: String) throws {
        guard id != Playlist.favoritesID else { return }
        try transaction {
            for sql in ["DELETE FROM playlist_items WHERE playlist_id = ?", "DELETE FROM playlists WHERE id = ?"] {
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                bind(statement, 1, id)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            }
        }
    }

    // MARK: - Album overrides

    func allOverrides() throws -> [String: AlbumOverride] {
        var overrides: [String: AlbumOverride] = [:]
        try query("SELECT album_key, title, artist, year, artwork_file FROM album_overrides") { row in
            let key = Self.text(row, 0) ?? ""
            overrides[key] = AlbumOverride(albumKey: key, title: Self.text(row, 1), artist: Self.text(row, 2),
                                           year: Self.int(row, 3), artworkFile: Self.text(row, 4))
        }
        return overrides
    }

    /// Saves an override; an empty one is deleted.
    func setOverride(_ override: AlbumOverride) throws {
        if override.isEmpty {
            let statement = try prepare("DELETE FROM album_overrides WHERE album_key = ?")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, override.albumKey)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            return
        }
        let statement = try prepare("INSERT OR REPLACE INTO album_overrides (album_key, title, artist, year, artwork_file) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, override.albumKey)
        bind(statement, 2, override.title)
        bind(statement, 3, override.artist)
        bind(statement, 4, override.year)
        bind(statement, 5, override.artworkFile)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    // MARK: - Track overrides

    func allTrackOverrides() throws -> [String: TrackOverride] {
        var overrides: [String: TrackOverride] = [:]
        try query("SELECT track_id, title, artist, album, album_artist, track_number, disc_number, year, composer, genre, group_key FROM track_overrides") { row in
            let id = Self.text(row, 0) ?? ""
            overrides[id] = TrackOverride(trackID: id, title: Self.text(row, 1), artist: Self.text(row, 2),
                                          album: Self.text(row, 3), albumArtist: Self.text(row, 4),
                                          trackNumber: Self.int(row, 5), discNumber: Self.int(row, 6),
                                          year: Self.int(row, 7), composer: Self.text(row, 8),
                                          genre: Self.text(row, 9), groupKey: Self.text(row, 10))
        }
        return overrides
    }

    func saveTrackOverrides(_ overrides: [TrackOverride]) throws {
        guard !overrides.isEmpty else { return }
        try transaction { try writeTrackOverrides(overrides) }
    }

    func saveAlbumAssignment(_ changes: [TrackOverride], albumOverride: AlbumOverride?) throws {
        try transaction {
            if let albumOverride { try setOverride(albumOverride) }
            try writeTrackOverrides(changes)
        }
    }

    private func writeTrackOverrides(_ overrides: [TrackOverride]) throws {
        let insert = try prepare("INSERT OR REPLACE INTO track_overrides (track_id, title, artist, album, album_artist, track_number, disc_number, year, composer, genre, group_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(insert) }
        let delete = try prepare("DELETE FROM track_overrides WHERE track_id = ?")
        defer { sqlite3_finalize(delete) }
        for override in overrides {
            let statement = override.isEmpty ? delete : insert
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(statement, 1, override.trackID)
            if !override.isEmpty {
                bind(statement, 2, override.title)
                bind(statement, 3, override.artist)
                bind(statement, 4, override.album)
                bind(statement, 5, override.albumArtist)
                bind(statement, 6, override.trackNumber)
                bind(statement, 7, override.discNumber)
                bind(statement, 8, override.year)
                bind(statement, 9, override.composer)
                bind(statement, 10, override.genre)
                bind(statement, 11, override.groupKey)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    // MARK: - SQLite helpers

    private static func track(from row: OpaquePointer) -> Track {
        Track(id: text(row, 0) ?? "", title: text(row, 1) ?? "", artist: text(row, 2) ?? "", album: text(row, 3) ?? "",
              trackNumber: Int(sqlite3_column_int64(row, 5)), duration: sqlite3_column_double(row, 11),
              codec: text(row, 12) ?? "", sampleRate: sqlite3_column_double(row, 13),
              bitDepth: Int(sqlite3_column_int64(row, 14)), fileSize: sqlite3_column_int64(row, 15),
              modified: Date(timeIntervalSince1970: sqlite3_column_double(row, 16)),
              year: int(row, 7), albumArtist: text(row, 4), discNumber: int(row, 6),
              composer: text(row, 8), genre: text(row, 9), isCompilation: int(row, 10).map { $0 != 0 })
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(row, column) else { return nil }
        return String(cString: pointer)
    }

    private static func int(_ row: OpaquePointer, _ column: Int32) -> Int? {
        sqlite3_column_type(row, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(row, column))
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(statement, index, value, -1, Self.transient) } else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int64(statement, index, Int64(value)) } else { sqlite3_bind_null(statement, index) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }

    private func query(_ sql: String, row: (OpaquePointer) -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { row(statement); continue }
            if result == SQLITE_DONE { return }
            throw error()
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func error() -> DatabaseError {
        .sqlite(String(cString: sqlite3_errmsg(handle)))
    }
}

/// What a scan has to do, from the files on disk and the rows in the database.
enum ScanDiff {
    struct Result: Equatable {
        /// New or changed files, sorted so albums fill in folder by folder.
        var toRead: [String]
        /// Rows whose file is gone.
        var removed: [String]
        var unchanged: Int
    }

    static func compute(onDisk: [String: LibraryDatabase.Stamp], inDatabase: [String: LibraryDatabase.Stamp]) -> Result {
        var toRead: [String] = []
        var unchanged = 0
        for (id, stamp) in onDisk {
            if let known = inDatabase[id], known.size == stamp.size, abs(known.modified - stamp.modified) < 0.001 {
                unchanged += 1
            } else {
                toRead.append(id)
            }
        }
        let removed = inDatabase.keys.filter { onDisk[$0] == nil }
        return Result(toRead: toRead.sorted(), removed: removed.sorted(), unchanged: unchanged)
    }
}
