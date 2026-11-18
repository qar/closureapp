import SwiftUI

struct AlbumView: View {
    let albumID: String
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @State private var pendingDelete: Track?
    @State private var confirmingAlbumDelete = false
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var findingInfo = false

    private var album: Album? { library.albums.first { $0.id == albumID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackBar(title: "Library") {
                    if album != nil {
                        MoreMenu {
                            Button("Edit Album…", systemImage: "pencil") { editing = true }
                            Button("Find Info Online…", systemImage: "magnifyingglass") { findingInfo = true }
                            Divider()
                            Button("Delete Album…", systemImage: "trash", role: .destructive) { confirmingAlbumDelete = true }
                        }
                    }
                }
                if let album {
                    header(album)
                    trackList(album)
                } else {
                    Text("This album is no longer in the library.")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.muted)
                        .padding(Theme.horizontalMargin)
                }
            }
            .padding(.bottom, 32)
        }
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
#if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            // -ClosureEditApply: save a sample edit (title, year, a drawn cover), for screenshots.
            if arguments.contains("-ClosureEditApply"), let album, !album.isEdited {
                let cover = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).jpegData(withCompressionQuality: 0.9) { context in
                    UIColor(red: 0.16, green: 0.20, blue: 0.27, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
                    UIColor(red: 0.83, green: 0.32, blue: 0.16, alpha: 1).setFill()
                    context.fill(CGRect(x: 60, y: 380, width: 480, height: 24))
                }
                await library.saveAlbumEdit(album.id, title: "Edited Title", artist: nil, year: 1999, cover: cover, removeCover: false)
            }
            if arguments.contains("-ClosureEdit") { editing = true }
            if arguments.contains("-ClosureFindInfo") { findingInfo = true }
        }
#endif
        .sheet(isPresented: $findingInfo) {
            if let album {
                FindInfoView(album: album)
                    .presentationBackground(Theme.paper)
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $editing) {
            if let album {
                AlbumEditView(album: album)
                    .presentationBackground(Theme.paper)
                    .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog("Delete this album?", isPresented: $confirmingAlbumDelete, titleVisibility: .visible) {
            if let album {
                Button("Delete \u{201C}\(album.title)\u{201D}", role: .destructive) {
                    Task {
                        await library.deleteAlbum(album)
                        dismiss()
                    }
                }
            }
        } message: {
            Text(albumDeleteMessage)
        }
        .confirmationDialog("Delete this track?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { track in
            Button("Delete \u{201C}\(track.title)\u{201D}", role: .destructive) {
                Task { await library.delete(track) }
            }
        } message: { _ in
            Text("It moves to Recently Deleted. You can restore it for 30 days.")
        }
    }

    private var albumDeleteMessage: String {
        let count = album?.tracks.count ?? 0
        let tracks = count == 1 ? "The track moves" : "All \(count) tracks move"
        return "\(tracks) to Recently Deleted, with the cover and other files in the album's folder. You can restore them for 30 days."
    }

    /// Layout "B · small cover side by side" (Figma: MM-Test › Closure iOS).
    /// A 112 pt cover with the title, edition and artist beside it; the title's
    /// cap height lines up with the cover's top edge. Below: one meta line and the
    /// quiet text actions.
    private func header(_ album: Album) -> some View {
        let parts = AlbumTitleParts(album.title)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ArtworkView(request: album.artworkRequest, title: album.title, pixelSize: 360)
                    .frame(width: 112, height: 112)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.ink.opacity(0.1), lineWidth: 1))
                VStack(alignment: .leading, spacing: 0) {
                    Text(parts.main)
                        .font(Theme.serif(28, relativeTo: .title))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(3)
                        .minimumScaleFactor(0.72)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let edition = parts.edition {
                        Text(edition)
                            .font(Theme.serif(17, relativeTo: .subheadline))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                    Text(album.artist)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                        .padding(.top, 4)
                }
                // Optical alignment: the serif line box starts above the cap height.
                .padding(.top, -4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            MetaText(metaLine(album), size: 10.5, tracking: 1)
                .padding(.top, 22)

            HStack(spacing: 24) {
                TextAction(title: "Play", systemImage: "play.fill") {
                    player.play(album.tracks, from: 0, context: album.title, shuffled: false)
                }
                if album.tracks.count > 1 {
                    TextAction(title: "Shuffle", systemImage: "shuffle") {
                        player.play(album.tracks, from: 0, context: album.title, shuffled: true)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .padding(.top, 12)
    }

    private func trackList(_ album: Album) -> some View {
        LazyVStack(spacing: 0) {
            Hairline()
            let showsDiscs = album.discs.count > 1
            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                // A "DISC n" header before the first track of each disc, for multi-disc albums.
                if showsDiscs, index == 0 || album.tracks[index - 1].discNumber != track.discNumber {
                    MetaText("Disc \(track.discNumber ?? 1)", size: 10.5, color: Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, index == 0 ? 16 : 28)
                        .padding(.bottom, 10)
                        .accessibilityAddTraits(.isHeader)
                    Hairline()
                }
                Button { player.play(album.tracks, from: index, context: album.title) } label: {
                    TrackRow(number: track.trackNumber > 0 ? track.trackNumber : index + 1,
                             title: track.title, duration: track.duration,
                             isCurrent: player.currentTrack?.id == track.id)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    TrackMenuItems(tracks: [track], context: album.title)
                    Divider()
                    Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = track }
                }
                Hairline()
            }
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .padding(.top, 14)
    }

    private func metaLine(_ album: Album) -> String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("\(album.tracks.count) track\(album.tracks.count == 1 ? "" : "s")")
        parts.append("\(max(1, Int((album.duration / 60).rounded()))) min")
        parts.append(album.format)
        return parts.joined(separator: " · ")
    }
}

struct ArtistView: View {
    let artist: String
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let albums = library.albums.filter { $0.artist == artist }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackBar(title: "Artists")
                Text(artist)
                    .font(Theme.serif(40))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, Theme.horizontalMargin)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                MetaText("\(albums.count) album\(albums.count == 1 ? "" : "s")", size: 10)
                    .padding(.horizontal, Theme.horizontalMargin)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                AlbumGrid(albums: albums)
            }
            .padding(.bottom, 32)
        }
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The tracks in one library folder, in file order.
struct FolderView: View {
    let folder: String
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let tracks = library.albums.flatMap(\.tracks)
            .filter { $0.folder == folder }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        let name = folder.split(separator: "/").last.map(String.init) ?? "Library"
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackBar(title: "Folders")
                Text(name)
                    .font(Theme.serif(40))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, Theme.horizontalMargin)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                MetaText(folder, size: 9.5, tracking: 1)
                    .padding(.horizontal, Theme.horizontalMargin)
                    .padding(.top, 6)
                HStack(spacing: 24) {
                    TextAction(title: "Play", systemImage: "play.fill") { player.play(tracks, from: 0, context: name, shuffled: false) }
                    TextAction(title: "Shuffle", systemImage: "shuffle") { player.play(tracks, from: 0, context: name, shuffled: true) }
                }
                .padding(.horizontal, Theme.horizontalMargin)
                .padding(.top, 6)
                LazyVStack(spacing: 0) {
                    Hairline()
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button { player.play(tracks, from: index, context: name) } label: {
                            TrackRow(number: index + 1, title: track.title,
                                     subtitle: track.url.lastPathComponent, duration: track.duration,
                                     isCurrent: player.currentTrack?.id == track.id)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TrackMenuItems(tracks: [track], context: name) }
                        Hairline()
                    }
                }
                .padding(.horizontal, Theme.horizontalMargin)
                .padding(.top, 28)
            }
            .padding(.bottom, 32)
        }
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
