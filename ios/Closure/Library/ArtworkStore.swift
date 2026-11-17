import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UIKit

/// Finds album artwork and keeps small thumbnails.
///
/// Order: an image file in the album folder (cover, folder, front, …), then a picture
/// embedded in the first tracks. FLAC pictures are read directly from the file because
/// AVFoundation does not expose them. Thumbnails are cached as JPEG in Caches, so the
/// full-size picture is decoded once.
actor ArtworkStore {
    static let shared = ArtworkStore()

    struct Request: Sendable {
        let key: String
        let directory: URL
        let sampleTracks: [URL]
        let stamp: TimeInterval
        /// A cover the user chose; used before anything in the files.
        var override: URL? = nil
    }

    private let memory = NSCache<NSString, UIImage>()
    private var misses: Set<String> = []
    private let cacheFolder: URL

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic"]
    private static let preferredNames = ["cover", "folder", "front", "album", "artwork"]

    init() {
        cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        memory.countLimit = 120
    }

    func image(for request: Request, pixelSize: Int = 720) async -> UIImage? {
        // v2: square thumbnails sized by the short edge (v1 used the long edge, which
        // left non-square images blurry once cropped to a square).
        let cacheKey = "v2|\(request.key)|\(request.stamp)|\(pixelSize)"
        if let image = memory.object(forKey: cacheKey as NSString) { return image }
        if misses.contains(cacheKey) { return nil }

        let file = cacheFolder.appendingPathComponent(Self.hash(cacheKey) + ".jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: cacheKey as NSString)
            return image
        }

        guard let source = await Self.findArtwork(request),
              let thumbnail = Self.downsample(source, maxPixel: pixelSize) else {
            misses.insert(cacheKey)
            return nil
        }
        if let jpeg = thumbnail.jpegData(compressionQuality: 0.86) {
            try? jpeg.write(to: file, options: .atomic)
        }
        memory.setObject(thumbnail, forKey: cacheKey as NSString)
        return thumbnail
    }

    /// New files may have brought artwork that was missing before.
    func forgetMisses() {
        misses.removeAll()
    }

    // MARK: - Finding artwork

    private static func findArtwork(_ request: Request) async -> Data? {
        if let override = request.override, let data = try? Data(contentsOf: override) { return data }
        for directory in searchDirectories(for: request.directory) {
            if let data = folderImage(in: directory) { return data }
        }
        for track in request.sampleTracks.prefix(2) {
            if let data = await embeddedPicture(in: track) { return data }
        }
        return nil
    }

    /// The album folder, plus its parent for "CD1"/"Disc 2" style subfolders.
    private static func searchDirectories(for directory: URL) -> [URL] {
        let name = directory.lastPathComponent.lowercased()
        let isDiscFolder = ["cd", "disc", "disk"].contains { name.hasPrefix($0) }
            && name.contains { $0.isNumber }
        return isDiscFolder ? [directory, directory.deletingLastPathComponent()] : [directory]
    }

    private static func folderImage(in directory: URL) -> Data? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let images = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let preferred = images.first { image in
            let base = image.deletingPathExtension().lastPathComponent.lowercased()
            return preferredNames.contains { base == $0 || base.hasPrefix($0 + " ") || base.hasPrefix($0 + "_") }
        }
        // A single image in an album folder is almost always its cover.
        guard let chosen = preferred ?? (images.count == 1 ? images.first : nil) else { return nil }
        return try? Data(contentsOf: chosen)
    }

    private static func embeddedPicture(in url: URL) async -> Data? {
        if url.pathExtension.lowercased() == "flac", let data = FLACPicture.frontCover(in: url) {
            return data
        }
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }

    // MARK: - Helpers

    private static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        squareThumbnail(data, side: maxPixel).map { UIImage(cgImage: $0) }
    }

    /// A square image of at most `side` pixels from the middle of `data`. Covers show
    /// as squares, so the short edge decides the size: scaling by the long edge would
    /// leave a tall or wide image too small once cropped.
    static func squareThumbnail(_ data: Data, side: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
        var maxPixel = side
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0 {
            let long = max(width, height), short = min(width, height)
            // Enough on the long edge for the short edge to reach `side`, never above the original.
            maxPixel = min(long, Int((Double(side) * Double(long) / Double(short)).rounded(.up)))
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        let edge = min(image.width, image.height)
        guard image.width != image.height else { return image }
        let crop = CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2, width: edge, height: edge)
        return image.cropping(to: crop) ?? image
    }

    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads PICTURE metadata blocks from a FLAC file.
enum FLACPicture {
    /// The front cover (picture type 3), or the first picture if there is no front cover.
    static func frontCover(in url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var magic = try? handle.read(upToCount: 4) else { return nil }
        // Some taggers put an ID3v2 tag in front of the FLAC stream. Skip it.
        if magic.starts(with: Data("ID3".utf8)),
           let rest = try? handle.read(upToCount: 6), rest.count == 6 {
            let size = Int(rest[2] & 0x7F) << 21 | Int(rest[3] & 0x7F) << 14 | Int(rest[4] & 0x7F) << 7 | Int(rest[5] & 0x7F)
            let hasFooter = rest[1] & 0x10 != 0
            try? handle.seek(toOffset: UInt64(10 + size + (hasFooter ? 10 : 0)))
            guard let next = try? handle.read(upToCount: 4) else { return nil }
            magic = next
        }
        guard magic == Data("fLaC".utf8) else { return nil }

        var firstPicture: Data?
        while true {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])

            if type == 6 {
                guard let block = try? handle.read(upToCount: length), block.count == length else { break }
                if let picture = parse(block) {
                    if picture.type == 3 { return picture.data }
                    if firstPicture == nil { firstPicture = picture.data }
                }
            } else {
                guard let offset = try? handle.offset() else { break }
                try? handle.seek(toOffset: offset + UInt64(length))
            }
            if isLast { break }
        }
        return firstPicture
    }

    static func parse(_ block: Data) -> (type: UInt32, data: Data)? {
        let bytes = [UInt8](block)
        var index = 0
        func readUInt32() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            defer { index += 4 }
            return bytes[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func skip(_ count: Int) -> Bool {
            guard count >= 0, index + count <= bytes.count else { return false }
            index += count
            return true
        }

        guard let type = readUInt32(),
              let mimeLength = readUInt32(), skip(Int(mimeLength)),
              let descriptionLength = readUInt32(), skip(Int(descriptionLength)),
              skip(16), // width, height, colour depth, palette size
              let dataLength = readUInt32(),
              index + Int(dataLength) <= bytes.count else { return nil }
        return (type, Data(bytes[index..<index + Int(dataLength)]))
    }
}
