import SwiftUI

struct TrackEditView: View {
    let track: Track
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var albumArtist: String
    @State private var trackNumber: String
    @State private var discNumber: String
    @State private var year: String
    @State private var composer: String
    @State private var genre: String
    @State private var saving = false
    @State private var error: String?

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
        _albumArtist = State(initialValue: track.albumArtist ?? "")
        _trackNumber = State(initialValue: track.trackNumber > 0 ? String(track.trackNumber) : "")
        _discNumber = State(initialValue: track.discNumber.map(String.init) ?? "")
        _year = State(initialValue: track.year.map(String.init) ?? "")
        _composer = State(initialValue: track.composer ?? "")
        _genre = State(initialValue: track.genre ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Save") { save() }.disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .font(.system(size: 17))
                .frame(minHeight: 44)
                Text("Edit Track")
                    .font(Theme.serif(32))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 12)
                UnderlineField(label: "Title", text: $title, placeholder: track.title).padding(.top, 24)
                UnderlineField(label: "Artist", text: $artist, placeholder: track.artist).padding(.top, 20)
                UnderlineField(label: "Album", text: $album, placeholder: track.album).padding(.top, 20)
                UnderlineField(label: "Album Artist", text: $albumArtist, placeholder: "Unknown").padding(.top, 20)
                UnderlineField(label: "Track Number", text: $trackNumber, placeholder: "Unknown", keyboard: .numberPad).padding(.top, 20)
                UnderlineField(label: "Disc Number", text: $discNumber, placeholder: "Unknown", keyboard: .numberPad).padding(.top, 20)
                UnderlineField(label: "Year", text: $year, placeholder: "Unknown", keyboard: .numberPad).padding(.top, 20)
                UnderlineField(label: "Composer", text: $composer, placeholder: "Unknown").padding(.top, 20)
                UnderlineField(label: "Genre", text: $genre, placeholder: "Unknown").padding(.top, 20)
                Button("Restore File Tags", systemImage: "arrow.uturn.backward") { restore() }
                    .padding(.top, 28)
                    .disabled(saving)
                if let error {
                    Text(error).foregroundStyle(.red).padding(.top, 16)
                }
            }
            .padding(.horizontal, Theme.horizontalMargin)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper.ignoresSafeArea())
    }

    private func save() {
        saving = true
        Task {
            var edit = await library.trackOverride(for: track.id)
            func clean(_ text: String) -> String? {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            if title != track.title { edit.title = clean(title) }
            if artist != track.artist { edit.artist = clean(artist) }
            if album != track.album { edit.album = clean(album) }
            if albumArtist != (track.albumArtist ?? "") { edit.albumArtist = clean(albumArtist) }
            if trackNumber != (track.trackNumber > 0 ? String(track.trackNumber) : "") {
                edit.trackNumber = Int(trackNumber).flatMap { $0 > 0 ? $0 : nil }
            }
            if discNumber != (track.discNumber.map(String.init) ?? "") {
                edit.discNumber = Int(discNumber).flatMap { $0 > 0 ? $0 : nil }
            }
            if year != (track.year.map(String.init) ?? "") {
                edit.year = Int(year).flatMap { (1000...2999).contains($0) ? $0 : nil }
            }
            if composer != (track.composer ?? "") { edit.composer = clean(composer) }
            if genre != (track.genre ?? "") { edit.genre = clean(genre) }
            do {
                try await library.saveTrackEdit(edit)
                dismiss()
            } catch {
                self.error = String(describing: error)
                saving = false
            }
        }
    }

    private func restore() {
        saving = true
        Task {
            let current = await library.trackOverride(for: track.id)
            do {
                try await library.saveTrackEdit(TrackOverride(trackID: track.id, groupKey: current.groupKey))
                dismiss()
            } catch {
                self.error = String(describing: error)
                saving = false
            }
        }
    }
}
