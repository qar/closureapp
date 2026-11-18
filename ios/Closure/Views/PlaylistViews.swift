import SwiftUI

// MARK: - Add to Playlist

/// Opens the playlist picker for some tracks. Set by `AddToPlaylistHost`.
struct AddToPlaylistAction {
    let run: ([Track]) -> Void
    func callAsFunction(_ tracks: [Track]) { run(tracks) }
}

extension EnvironmentValues {
    @Entry var addToPlaylist: AddToPlaylistAction?
}

/// Presents the playlist picker for menus inside it (the library, Now Playing).
struct AddToPlaylistHost: ViewModifier {
    private struct Pending: Identifiable {
        let id = UUID()
        let tracks: [Track]
    }

    @State private var pending: Pending?

    func body(content: Content) -> some View {
        content
            .environment(\.addToPlaylist, AddToPlaylistAction { pending = Pending(tracks: $0) })
            .sheet(item: $pending) { item in
                AddToPlaylistView(tracks: item.tracks)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Theme.paper)
                    .presentationDragIndicator(.visible)
            }
    }
}

/// Pick a playlist for some tracks, or make a new one with them.
struct AddToPlaylistView: View {
    let tracks: [Track]
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Add to Playlist")
                    .font(Theme.serif(32))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 28)
                    .accessibilityAddTraits(.isHeader)
                MetaText(tracks.count == 1 ? tracks[0].title : "\(tracks.count) tracks", size: 10)
                    .padding(.top, 6)
                    .padding(.bottom, 20)
                Hairline()
                Button { naming = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").font(.system(size: 16, weight: .medium)).frame(width: 24)
                        Text("New Playlist…").font(.system(size: 17))
                        Spacer()
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Hairline()
                ForEach(library.playlists) { playlist in
                    let has = Set(playlist.trackIDs)
                    let allThere = tracks.allSatisfy { has.contains($0.id) }
                    Button {
                        Task {
                            await library.add(tracks, to: playlist.id)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: playlist.isFavorites ? "heart" : "music.note.list")
                                .font(.system(size: 16)).frame(width: 24)
                            Text(playlist.name).font(.system(size: 17)).lineLimit(1)
                            Spacer()
                            MetaText(allThere ? "Added" : "\(playlist.tracks(in: library.tracksByID).count)", size: 10)
                        }
                        .foregroundStyle(allThere ? Theme.muted : Theme.ink)
                        .padding(.vertical, 15)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(allThere)
                    Hairline()
                }
            }
            .padding(.horizontal, Theme.horizontalMargin)
            .padding(.bottom, 24)
        }
        .alert("New Playlist", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                let name = newName
                newName = ""
                Task {
                    await library.createPlaylist(named: name, with: tracks)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Playlist page

/// One playlist: play or shuffle it, reorder (Edit) or swipe tracks away. Favorites
/// cannot be renamed or deleted.
struct PlaylistView: View {
    let playlistID: String
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false

    var body: some View {
        let playlist = library.playlist(playlistID)
        let tracks = playlist?.tracks(in: library.tracksByID) ?? []
        List {
            Group {
                BackBar(title: "Library") {
                    if let playlist {
                        MoreMenu {
                            if !playlist.isFavorites {
                                Button("Rename…", systemImage: "pencil") {
                                    newName = playlist.name
                                    renaming = true
                                }
                            }
                            if !tracks.isEmpty {
                                Button(editMode.isEditing ? "Done Editing" : "Edit Order", systemImage: "arrow.up.arrow.down") {
                                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                                }
                            }
                            if !playlist.isFavorites {
                                Button("Delete Playlist…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                            }
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
                header(playlist, tracks: tracks)
                    .listRowInsets(EdgeInsets(top: 0, leading: Theme.horizontalMargin, bottom: 14, trailing: Theme.horizontalMargin))
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.paper)
            .moveDisabled(true)
            .deleteDisabled(true)

            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button { player.play(tracks, from: index, context: playlist?.name ?? "") } label: {
                    TrackRow(number: index + 1, title: track.title, subtitle: track.artist, duration: track.duration,
                             isCurrent: player.currentTrack?.id == track.id)
                        .padding(.trailing, editMode.isEditing ? 12 : 0)
                }
                .buttonStyle(.plain)
                .contextMenu { TrackMenuItems(tracks: [track], context: playlist?.name ?? "") }
                .listRowInsets(EdgeInsets(top: 0, leading: Theme.horizontalMargin, bottom: 0, trailing: Theme.horizontalMargin))
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.paper.overlay(alignment: .bottom) {
                    Hairline().padding(.horizontal, Theme.horizontalMargin)
                })
                .deleteDisabled(editMode.isEditing)
            }
            .onMove { source, destination in Task { await library.movePlaylistItems(playlistID, from: source, to: destination) } }
            .onDelete { offsets in Task { await library.removeFromPlaylist(playlistID, at: offsets) } }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .environment(\.editMode, $editMode)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await library.renamePlaylist(playlistID, to: newName) } }
        }
        .confirmationDialog("Delete \u{201C}\(playlist?.name ?? "")\u{201D}?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                Task {
                    await library.deletePlaylist(playlistID)
                    dismiss()
                }
            }
        } message: {
            Text("The tracks stay in your library.")
        }
    }

    @ViewBuilder
    private func header(_ playlist: Playlist?, tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(playlist?.name ?? "Playlist")
                .font(Theme.serif(36))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            MetaText(meta(tracks), size: 10.5, tracking: 1).padding(.top, 8)
            if tracks.isEmpty {
                Text(playlist?.isFavorites == true
                     ? "Tracks you add to Favorites appear here. Press and hold a track, then choose Add to Favorites."
                     : "Press and hold a track or an album, then choose Add to Playlist.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
            } else {
                HStack(spacing: 24) {
                    TextAction(title: "Play", systemImage: "play.fill") {
                        player.play(tracks, from: 0, context: playlist?.name ?? "", shuffled: false)
                    }
                    if tracks.count > 1 {
                        TextAction(title: "Shuffle", systemImage: "shuffle") {
                            player.play(tracks, from: 0, context: playlist?.name ?? "", shuffled: true)
                        }
                    }
                }
                .padding(.top, 2)
                Hairline().padding(.top, 14)
            }
        }
    }

    private func meta(_ tracks: [Track]) -> String {
        let minutes = Int((tracks.reduce(0) { $0 + $1.duration } / 60).rounded())
        return "\(tracks.count) track\(tracks.count == 1 ? "" : "s")" + (tracks.isEmpty ? "" : " · \(max(1, minutes)) min")
    }
}
