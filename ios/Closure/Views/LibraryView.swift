import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @State private var showingImporter = false
    @State private var showingNowPlaying = false

    var body: some View {
        NavigationStack {
            Group {
                if library.albums.isEmpty {
                    ContentUnavailableView {
                        Label("No Music", systemImage: "music.note")
                    } description: {
                        Text("Tap + to import files or folders, or copy music to Closure in Finder.")
                    }
                } else {
                    albumList
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if library.isImporting {
                        ProgressView()
                    } else {
                        Button("Import", systemImage: "plus") { showingImporter = true }
                    }
                }
            }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.audio, .folder],
                          allowsMultipleSelection: true) { result in
                if case let .success(urls) = result {
                    Task { await library.importItems(urls) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.currentTrack != nil {
                    NowPlayingBar { showingNowPlaying = true }
                }
            }
            .sheet(isPresented: $showingNowPlaying) {
                NowPlayingView()
                    .presentationDragIndicator(.visible)
            }
#if DEBUG
            .task(id: library.albums.count) { runDebugLaunchArguments() }
#endif
        }
    }

#if DEBUG
    /// Simulator checks without taps: -ClosureAutoplay plays the first album,
    /// -ClosureShowNowPlaying also opens the now playing sheet.
    private func runDebugLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ClosureAutoplay"), player.currentTrack == nil,
              let album = library.albums.first else { return }
        player.play(album.tracks, from: 0)
        showingNowPlaying = arguments.contains("-ClosureShowNowPlaying")
    }
#endif

    private var albumList: some View {
        List {
            if let message = library.lastImportMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(library.albums) { album in
                Section {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, isCurrent: player.currentTrack?.id == track.id)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(album.tracks, from: index) }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    Task { await library.delete(track) }
                                }
                            }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title).font(.headline).foregroundStyle(.primary)
                        Text(album.artist).font(.subheadline)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct TrackRow: View {
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(track.trackNumber > 0 ? "\(track.trackNumber)" : "–")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Text(track.formatSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(formatTime(track.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
}
