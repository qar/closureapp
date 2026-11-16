import Foundation

/// What was playing, saved so playback can continue after the app is closed or the
/// system ends it: the queue (library-relative paths), the current track, the
/// position in it, where the queue came from, and the repeat mode.
struct PlaybackState: Codable, Equatable {
    var trackIDs: [String]
    var index: Int
    var position: Double
    var context: String
    /// CLSRepeatMode raw value.
    var repeatMode: Int

    /// The saved queue matched against the current library. Tracks deleted since are
    /// left out. When the current track is gone, playback continues with the next
    /// track that is still there, from its start. Nil when nothing is left.
    func restore(from library: [String: Track]) -> (tracks: [Track], index: Int, position: Double)? {
        guard trackIDs.indices.contains(index) else { return nil }
        var tracks: [Track] = []
        var newIndex: Int?
        var newPosition = 0.0
        for (offset, id) in trackIDs.enumerated() {
            guard let track = library[id] else { continue }
            if newIndex == nil, offset >= index {
                newIndex = tracks.count
                newPosition = offset == index ? position : 0
            }
            tracks.append(track)
        }
        guard !tracks.isEmpty else { return nil }
        // The current track and everything after it are gone: start the queue over.
        let start = newIndex ?? 0
        if newIndex == nil { newPosition = 0 }
        // A position at (or past) the very end restarts the track rather than ending it at once.
        let duration = tracks[start].duration
        if duration > 0, newPosition >= duration - 1 { newPosition = 0 }
        return (tracks, start, max(0, newPosition))
    }

    static func load(from url: URL) -> PlaybackState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PlaybackState.self, from: data)
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static var appURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Playback/state.json")
    }
}
