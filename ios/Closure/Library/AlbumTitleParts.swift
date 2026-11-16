import Foundation

/// Splits an edition suffix off an album title, so "Born To Die (The Paradise Edition)"
/// shows "Born To Die" with "The Paradise Edition" on its own line.
struct AlbumTitleParts: Equatable {
    let main: String
    let edition: String?

    init(main: String, edition: String?) {
        self.main = main
        self.edition = edition
    }

    private static let editionWords = ["edition", "deluxe", "remaster", "anniversary", "expanded",
                                       "version", "live", "mono", "stereo", "bonus", "reissue", "mix"]

    init(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        // Trailing "(…)" or "[…]".
        for (open, close) in [("(", ")"), ("[", "]")] where trimmed.hasSuffix(close) {
            if let start = trimmed.range(of: " " + open, options: .backwards) {
                let main = String(trimmed[..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
                let inner = String(trimmed[start.upperBound..<trimmed.index(before: trimmed.endIndex)])
                if !main.isEmpty && !inner.isEmpty {
                    self.main = main
                    self.edition = inner
                    return
                }
            }
        }
        // Trailing " - Deluxe Edition" style suffix, only when it names an edition.
        for separator in [" - ", " – ", " — "] {
            if let range = trimmed.range(of: separator, options: .backwards) {
                let suffix = String(trimmed[range.upperBound...])
                let main = String(trimmed[..<range.lowerBound])
                if !main.isEmpty, Self.editionWords.contains(where: { suffix.lowercased().contains($0) }) {
                    self.main = main
                    self.edition = suffix
                    return
                }
            }
        }
        main = trimmed
        edition = nil
    }
}
