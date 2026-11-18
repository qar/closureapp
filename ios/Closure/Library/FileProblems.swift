import Foundation

/// A track that was in the library and whose file is gone, without the user deleting it.
struct MissingFile: Codable, Equatable, Identifiable {
    /// Library-relative path the file had.
    let id: String
    let title: String
    let artist: String
    let album: String
    let noticedAt: Date
}

/// Files the user should hear about: ones the engine cannot read, and ones that went
/// missing. Moving a track to Recently Deleted also takes its file away; those are not
/// missing.
enum FileProblems {
    static func missing(removed: [Track], trashedPaths: Set<String>, now: Date = Date()) -> [MissingFile] {
        removed.filter { !trashedPaths.contains($0.id) }.map {
            MissingFile(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album, noticedAt: now)
        }
    }

    /// Adds newly missing files to the saved list, newest first, without repeats.
    static func merge(_ new: [MissingFile], into saved: [MissingFile]) -> [MissingFile] {
        let known = Set(saved.map(\.id))
        return new.filter { !known.contains($0.id) } + saved
    }

    static func load(from url: URL) -> [MissingFile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([MissingFile].self, from: data)) ?? []
    }

    static func save(_ files: [MissingFile], to url: URL) {
        if files.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(files) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension Track {
    /// The engine could not open the file when it was read: an unsupported or damaged file.
    var isUnreadable: Bool { codec == "Unsupported" }
}
