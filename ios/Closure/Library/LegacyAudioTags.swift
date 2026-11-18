import Foundation

/// ID3v1 and APEv2 metadata from the end of an audio file. AVFoundation does not
/// expose these consistently, particularly when a file also has ID3v2 frames.
enum LegacyAudioTags {
    struct Result {
        var items: [TagItem] = []
        var frontCover: Data?
        var lyrics: String?
    }

    private static let maxAPESize = 16 * 1024 * 1024
    private static let maxItems = 1024
    private static let genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop",
        "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock",
        "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack",
        "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance",
        "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop",
        "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic",
        "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave",
        "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk",
        "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebop", "Latin",
        "Revival", "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock",
        "Psychedelic Rock", "Symphonic Rock", "Slow Rock", "Big Band", "Chorus", "Easy Listening",
        "Acoustic", "Humour", "Speech", "Chanson", "Opera", "Chamber Music", "Sonata",
        "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam", "Club",
        "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul",
        "Freestyle", "Duet", "Punk Rock", "Drum Solo", "A Cappella", "Euro-House",
        "Dance Hall", "Goa", "Drum & Bass", "Club-House", "Hardcore", "Terror", "Indie",
        "BritPop", "Negerpunk", "Polsk Punk", "Beat", "Christian Gangsta Rap", "Heavy Metal",
        "Black Metal", "Crossover", "Contemporary Christian", "Christian Rock", "Merengue",
        "Salsa", "Thrash Metal", "Anime", "JPop", "Synthpop",
    ]

    static func read(from url: URL) -> Result {
        guard let file = try? FileHandle(forReadingFrom: url) else { return Result() }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return Result() }

        var result = Result()
        var id3Length: UInt64 = 0
        if size >= 128,
           (try? file.seek(toOffset: size - 128)) != nil,
           let tail = try? file.read(upToCount: 128), tail.count == 128,
           tail.starts(with: Data("TAG".utf8)) {
            id3Length = 128
            result.items = parseID3v1(tail)
        }

        let footerEnd = size - id3Length
        guard footerEnd >= 32,
              (try? file.seek(toOffset: footerEnd - 32)) != nil,
              let footer = try? file.read(upToCount: 32), footer.count == 32,
              footer.starts(with: Data("APETAGEX".utf8)),
              let version = uint32(footer, at: 8), version == 1000 || version == 2000,
              let tagSize = uint32(footer, at: 12), tagSize >= 32, tagSize <= maxAPESize,
              let count = uint32(footer, at: 16), count <= maxItems,
              UInt64(tagSize) <= footerEnd else { return result }

        guard (try? file.seek(toOffset: footerEnd - UInt64(tagSize))) != nil,
              let tag = try? file.read(upToCount: Int(tagSize)), tag.count == Int(tagSize) else { return result }
        let ape = parseAPE(tag, count: Int(count))
        // AVFoundation metadata goes first at the call site; APEv2 goes before ID3v1.
        result.items = ape.items + result.items
        result.frontCover = ape.frontCover
        result.lyrics = ape.lyrics
        return result
    }

    private static func parseID3v1(_ tag: Data) -> [TagItem] {
        let bytes = [UInt8](tag)
        var items: [TagItem] = []
        func add(_ key: String, common: String? = nil, _ range: Range<Int>) {
            let field = Array(bytes[range]).prefix { $0 != 0 }
            let trimmed = Array(field).drop(while: { $0 == 0x20 }).reversed().drop(while: { $0 == 0x20 }).reversed()
            guard !trimmed.isEmpty else { return }
            let text = String(data: Data(trimmed), encoding: .isoLatin1) ?? ""
            items.append(TagItem(identifier: "id3v1/\(key)", commonKey: common,
                                 string: TagTextRepair.repairCJK(text), number: nil, data: nil))
        }
        add("TITLE", common: "title", 3..<33)
        add("ARTIST", common: "artist", 33..<63)
        add("ALBUM", common: "albumName", 63..<93)
        add("YEAR", common: "creationDate", 93..<97)
        if bytes[125] == 0, bytes[126] > 0 {
            items.append(TagItem(identifier: "id3v1/TRACK", commonKey: nil, string: nil,
                                 number: Int(bytes[126]), data: nil))
        }
        let genre = Int(bytes[127])
        if genres.indices.contains(genre) {
            items.append(TagItem(identifier: "id3v1/GENRE", commonKey: nil,
                                 string: genres[genre], number: nil, data: nil))
        }
        return items
    }

    private static func parseAPE(_ tag: Data, count: Int) -> Result {
        let bytes = [UInt8](tag)
        var offset = bytes.starts(with: Array("APETAGEX".utf8)) ? 32 : 0
        let end = bytes.count - 32 // Footer is part of tagSize.
        var result = Result()
        for _ in 0..<count {
            guard offset + 8 <= end,
                  let length = uint32(tag, at: offset),
                  let flags = uint32(tag, at: offset + 4) else { break }
            offset += 8
            guard let terminator = bytes[offset..<end].firstIndex(of: 0), terminator > offset,
                  terminator - offset <= 255,
                  let name = String(bytes: bytes[offset..<terminator], encoding: .utf8) else { break }
            offset = terminator + 1
            guard length <= end - offset else { break }
            let value = Data(bytes[offset..<offset + Int(length)])
            offset += Int(length)

            let key = name.uppercased()
            if key == "COVER ART (FRONT)", result.frontCover == nil,
               let separator = value.firstIndex(of: 0), separator + 1 < value.endIndex {
                result.frontCover = value.subdata(in: separator + 1..<value.endIndex)
            }
            guard (flags >> 1) & 3 == 0,
                  let text = String(data: value.prefix { $0 != 0 }, encoding: .utf8) else { continue }
            if ["LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS"].contains(key), result.lyrics == nil {
                result.lyrics = text
            }
            let common: String? = switch key {
            case "TITLE": "title"
            case "ARTIST": "artist"
            case "ALBUM": "albumName"
            case "YEAR", "DATE": "creationDate"
            default: nil
            }
            result.items.append(TagItem(identifier: "ape/\(key)", commonKey: common,
                                        string: text, number: nil, data: nil))
        }
        return result
    }

    private static func uint32(_ data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data[offset..<offset + 4].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
    }
}
