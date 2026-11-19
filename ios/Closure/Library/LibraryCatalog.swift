import AVFoundation
import Foundation

/// Reads one audio file: format through the playback engine, tags through AVFoundation.
/// Safe to call from any thread.
enum TrackReader {
    static func read(id: String, url: URL, size: Int64, modified: Date) async -> Track {
        let info = CLSEngine.probe(url.path)
        var items: [TagItem] = []
        if let metadata = try? await AVURLAsset(url: url).load(.metadata) {
            for item in metadata {
                items.append(TagItem(identifier: item.identifier?.rawValue ?? "",
                                     commonKey: item.commonKey?.rawValue,
                                     string: try? await item.load(.stringValue),
                                     number: (try? await item.load(.numberValue))?.intValue,
                                     data: try? await item.load(.dataValue)))
            }
        }
        items += LegacyAudioTags.read(from: url).items
        let tags = TagParser.parse(items)
        let fileName = url.deletingPathExtension().lastPathComponent
        let parentName = url.deletingLastPathComponent().lastPathComponent
        // Without a disc tag, a "CD2" folder still says which disc this is.
        let discFromFolder = tags.album == nil ? nil : LibraryGrouping.discNumber(fromFolderName: parentName)

        return Track(id: id,
                     title: tags.title ?? fileName,
                     artist: tags.artist ?? "",
                     album: tags.album ?? "",
                     // "01 Title.flac" style names when the tag is missing.
                     trackNumber: tags.trackNumber ?? Int(url.lastPathComponent.prefix { $0.isNumber }) ?? 0,
                     duration: info.durationSeconds,
                     codec: info.ok ? info.codec : "Unsupported",
                     sampleRate: info.sampleRate, bitDepth: info.bitDepth, fileSize: size, modified: modified,
                     year: tags.year,
                     albumArtist: tags.albumArtist,
                     discNumber: tags.discNumber ?? discFromFolder,
                     composer: tags.composer,
                     genre: tags.genre,
                     isCompilation: tags.isCompilation)
    }
}

/// Owns the library database and does all heavy library work away from the main
/// thread: loading, grouping and scanning.
actor LibraryCatalog {
    struct Progress: Sendable {
        var done: Int
        var total: Int
        /// Albums as they stand, sent about once a second while files are read.
        var snapshot: LibrarySnapshot?
    }

    private let database: LibraryDatabase?
    private var tracks: [String: Track] = [:]
    /// From the last scan: tracks whose files went away, and files read that the engine
    /// could not open.
    private(set) var lastRemoved: [Track] = []
    private(set) var lastNewlyUnreadable: [Track] = []
    /// The user's album edits, applied after grouping.
    private(set) var overrides: [String: AlbumOverride] = [:]
    private var trackOverrides: [String: TrackOverride] = [:]
    private static let readers = 4
    private static let publishInterval: TimeInterval = 1.0

    init(databaseURL: URL, legacyIndexURL: URL) {
        let database = try? LibraryDatabase(url: databaseURL)
        self.database = database
        Self.migrateLegacyIndex(from: legacyIndexURL, into: database)
    }

    /// Loads every row and groups it into albums.
    func load() -> LibrarySnapshot {
        let rows = (try? database?.allTracks()) ?? []
        tracks = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        overrides = (try? database?.allOverrides()) ?? [:]
        trackOverrides = (try? database?.allTrackOverrides()) ?? [:]
        return grouped()
    }

    /// Brings the database in line with the files under `root`. Unchanged files are
    /// skipped by size and modification time; new or changed files are read four at a
    /// time and written in batches.
    func scan(root: URL, progress: @escaping @Sendable (Progress) async -> Void) async -> LibrarySnapshot {
        let (onDisk, urls) = Self.listAudioFiles(under: root)
        let known = tracks.mapValues { LibraryDatabase.Stamp(size: $0.fileSize, modified: $0.modified.timeIntervalSince1970) }
        let diff = ScanDiff.compute(onDisk: onDisk, inDatabase: known)
        lastRemoved = diff.removed.compactMap { tracks[$0] }
        lastNewlyUnreadable = []

        if !diff.removed.isEmpty {
            try? database?.delete(ids: diff.removed)
            for id in diff.removed { tracks[id] = nil }
        }
        guard !diff.toRead.isEmpty else { return grouped() }

        await progress(Progress(done: 0, total: diff.toRead.count, snapshot: diff.removed.isEmpty ? nil : grouped()))
        var pending = diff.toRead.makeIterator()
        var batch: [Track] = []
        var done = 0
        var lastPublish = Date()

        await withTaskGroup(of: Track.self) { group in
            func addNext() {
                guard let id = pending.next(), let url = urls[id], let stamp = onDisk[id] else { return }
                group.addTask {
                    await TrackReader.read(id: id, url: url, size: stamp.size, modified: Date(timeIntervalSince1970: stamp.modified))
                }
            }
            for _ in 0..<Self.readers { addNext() }
            while let track = await group.next() {
                batch.append(track)
                done += 1
                addNext()
                if Date().timeIntervalSince(lastPublish) >= Self.publishInterval {
                    commit(&batch)
                    lastPublish = Date()
                    await progress(Progress(done: done, total: diff.toRead.count, snapshot: grouped()))
                }
            }
        }
        commit(&batch)
        return grouped()
    }

    private func commit(_ batch: inout [Track]) {
        guard !batch.isEmpty else { return }
        try? database?.upsert(batch)
        for track in batch {
            // Newly unreadable only: a file already known as unreadable is not news.
            if track.isUnreadable, tracks[track.id]?.isUnreadable != true { lastNewlyUnreadable.append(track) }
            tracks[track.id] = track
        }
        batch.removeAll(keepingCapacity: true)
    }

    private func grouped() -> LibrarySnapshot {
        let edited = tracks.values.map { trackOverrides[$0.id]?.apply(to: $0) ?? $0 }
        var snapshot = LibraryGrouping.snapshot(from: edited)
        snapshot.albums = AlbumOverrides.apply(overrides, to: snapshot.albums)
        return snapshot
    }

    // MARK: - Playlists

    func playlists() -> [Playlist] {
        (try? database?.allPlaylists()) ?? []
    }

    /// Saves a playlist. New playlists go after the existing ones.
    func savePlaylist(_ playlist: Playlist) -> [Playlist] {
        let existing = playlists()
        let order = existing.firstIndex { $0.id == playlist.id } ?? existing.count
        try? database?.savePlaylist(playlist, sortOrder: playlist.isFavorites ? 0 : max(1, order))
        return playlists()
    }

    func deletePlaylist(id: String) -> [Playlist] {
        try? database?.deletePlaylist(id: id)
        return playlists()
    }

    /// Saves an album edit and returns the albums with it applied.
    func setOverride(_ override: AlbumOverride) -> LibrarySnapshot {
        try? database?.setOverride(override)
        overrides[override.albumKey] = override.isEmpty ? nil : override
        return grouped()
    }

    func trackOverride(for id: String) -> TrackOverride {
        trackOverrides[id] ?? TrackOverride(trackID: id)
    }

    func saveTrackOverride(_ override: TrackOverride) throws -> LibrarySnapshot {
        guard let database else { throw LibraryDatabase.DatabaseError.sqlite("Library database unavailable") }
        guard tracks[override.trackID] != nil else { return grouped() }
        try database.saveTrackOverrides([override])
        trackOverrides[override.trackID] = override.isEmpty ? nil : override
        return grouped()
    }

    func moveTracks(_ ids: [String], to existingAlbumID: String?, newAlbum: (title: String, artist: String)?) throws -> LibrarySnapshot {
        guard let database else { throw LibraryDatabase.DatabaseError.sqlite("Library database unavailable") }
        let selected = Set(ids).filter { tracks[$0] != nil }
        guard !selected.isEmpty else { return grouped() }
        let target = existingAlbumID.flatMap { id in grouped().albums.first { $0.id == id } }
        guard target != nil || newAlbum != nil else {
            throw LibraryDatabase.DatabaseError.sqlite("Target album no longer exists")
        }
        let key = target?.id ?? "custom:\(UUID().uuidString)"
        let changes = selected.sorted().map { id -> TrackOverride in
            var edit = trackOverride(for: id)
            edit.groupKey = key
            return edit
        }
        let newOverride = newAlbum.map {
            AlbumOverride(albumKey: key, title: $0.title, artist: $0.artist, year: nil, artworkFile: nil)
        }
        try database.saveAlbumAssignment(changes, albumOverride: newOverride)
        if let newOverride { overrides[key] = newOverride }
        for change in changes { trackOverrides[change.trackID] = change }
        return grouped()
    }

    func restoreFileAlbum(for ids: [String]) throws -> LibrarySnapshot {
        guard let database else { throw LibraryDatabase.DatabaseError.sqlite("Library database unavailable") }
        let changes = Set(ids).filter { tracks[$0] != nil }.sorted().map { id -> TrackOverride in
            var edit = trackOverride(for: id)
            edit.groupKey = nil
            return edit
        }
        try database.saveTrackOverrides(changes)
        for change in changes { trackOverrides[change.trackID] = change.isEmpty ? nil : change }
        return grouped()
    }

    private static func listAudioFiles(under root: URL) -> ([String: LibraryDatabase.Stamp], [String: URL]) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var stamps: [String: LibraryDatabase.Stamp] = [:]
        var urls: [String: URL] = [:]
        let rootPath = root.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let file = enumerator?.nextObject() as? URL {
            guard FileImporter.kind(of: file) == .audio,
                  let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let id = String(file.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            stamps[id] = LibraryDatabase.Stamp(size: Int64(values.fileSize ?? 0),
                                               modified: (values.contentModificationDate ?? .distantPast).timeIntervalSince1970)
            urls[id] = file
        }
        return (stamps, urls)
    }

    /// The JSON index used before the database. Imported once, then removed.
    private struct LegacyIndex: Codable {
        var version: Int
        var tracks: [Track]
    }

    private static func migrateLegacyIndex(from url: URL, into database: LibraryDatabase?) {
        guard let database, FileManager.default.fileExists(atPath: url.path) else { return }
        if (try? database.trackCount()) == 0,
           let data = try? Data(contentsOf: url),
           let index = try? JSONDecoder().decode(LegacyIndex.self, from: data), index.version == 2 {
            let toRescan = index.tracks.map { track -> Track in
                var track = track
                track.modified = .distantPast
                return track
            }
            try? database.upsert(toRescan)
        }
        try? FileManager.default.removeItem(at: url)
    }

#if DEBUG
    /// Fills the database with synthetic tracks, for load-time measurements.
    func seedSynthetic(count: Int) {
        var rows: [Track] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            let album = index / 10
            rows.append(Track(id: "Synthetic/Artist \(album % 900)/Album \(album)/\(index % 10 + 1).flac",
                              title: "Track \(index % 10 + 1)", artist: "Artist \(album % 900)", album: "Album \(album)",
                              trackNumber: index % 10 + 1, duration: 240, codec: "FLAC", sampleRate: 44100, bitDepth: 16,
                              fileSize: 30_000_000, modified: Date(timeIntervalSince1970: 1_700_000_000), year: 2020,
                              albumArtist: "Artist \(album % 900)", discNumber: 1, composer: nil, genre: nil, isCompilation: nil))
        }
        try? database?.upsert(rows)
    }
#endif
}
