import Foundation

/// How much space the library takes, measured on disk, and how much the device has.
struct StorageSummary: Equatable {
    /// Everything in the library folder: audio, covers, lyrics.
    var music: Int64
    /// Files in Recently Deleted, still on disk until they expire.
    var recentlyDeleted: Int64
    /// Free space for important data (what iOS lets an app use), and the volume size.
    var free: Int64?
    var capacity: Int64?

    /// Measures the folders and reads the volume. Walks the files once; no file is read.
    static func measure(library: URL, trash: URL) -> StorageSummary {
        let volume = try? library.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return StorageSummary(music: allocatedSize(of: library), recentlyDeleted: allocatedSize(of: trash),
                              free: volume?.volumeAvailableCapacityForImportantUsage,
                              capacity: volume?.volumeTotalCapacity.map(Int64.init))
    }

    /// Bytes the files under `folder` take on disk.
    static func allocatedSize(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// Shares of the volume for the usage bar: the library, everything else used
    /// (Recently Deleted included), free.
    var shares: (music: Double, other: Double, free: Double)? {
        guard let capacity, capacity > 0, let free else { return nil }
        let total = Double(capacity)
        let music = min(1, Double(self.music) / total)
        let freeShare = min(1 - music, Double(free) / total)
        return (music, max(0, 1 - music - freeShare), freeShare)
    }
}

extension Album {
    /// Audio bytes of the album, from the library index (no disk access).
    var byteCount: Int64 { tracks.reduce(0) { $0 + $1.fileSize } }
}
