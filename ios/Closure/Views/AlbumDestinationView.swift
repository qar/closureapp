import SwiftUI

struct AlbumDestinationView: View {
    let tracks: [Track]
    let currentAlbumID: String
    let onMoved: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if tracks.contains(where: { $0.groupingKeyOverride != nil }) {
                    Section {
                        Button("Use File Tags", systemImage: "arrow.uturn.backward") {
                            perform { try await library.restoreFileAlbum(for: tracks) }
                        }
                        .disabled(saving)
                    }
                }
                Section("Existing Albums") {
                    ForEach(library.albums.filter { $0.id != currentAlbumID }) { album in
                        Button {
                            perform { try await library.moveTracks(tracks, to: album.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(album.title).foregroundStyle(Theme.ink)
                                Text(album.artist).font(.system(size: 13)).foregroundStyle(Theme.muted)
                            }
                            .frame(minHeight: 44, alignment: .leading)
                        }
                        .disabled(saving)
                    }
                }
                Section("New Album") {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    Button("Create Album", systemImage: "plus") {
                        perform {
                            let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
                            try await library.moveTracks(tracks, toNewAlbum: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                         artist: name.isEmpty ? (tracks.first?.artist ?? "Unknown Artist") : name)
                        }
                    }
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .navigationTitle(tracks.count == 1 ? "Move Track" : "Move \(tracks.count) Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        saving = true
        Task {
            do {
                try await action()
                onMoved()
                dismiss()
            } catch {
                self.error = String(describing: error)
                saving = false
            }
        }
    }
}
