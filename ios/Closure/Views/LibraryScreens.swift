import SwiftUI

struct EmptyLibraryView: View {
    let isImporting: Bool
    let onImport: () -> Void
    let onFinderHelp: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library")
                    .font(Theme.serif(46))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                IconButton(systemName: "plus", label: "Import", action: onImport)
            }
            .padding(.leading, Theme.horizontalMargin)
            .padding(.trailing, 14)
            .padding(.top, 8)

            Spacer()
            ZStack {
                Circle().stroke(Theme.ink.opacity(0.5), lineWidth: 1.2).frame(width: 140, height: 140)
                Circle().stroke(Theme.ink.opacity(0.35), lineWidth: 1.2).frame(width: 56, height: 56)
                Circle().fill(Theme.accent).frame(width: 12, height: 12)
            }
            .accessibilityHidden(true)

            Text(isImporting ? "Importing…" : "Nothing here yet")
                .font(Theme.serif(36))
                .foregroundStyle(Theme.ink)
                .padding(.top, 56)
            Text("Import music from the Files app, or copy album folders to Closure in Finder over a cable.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 48)
                .padding(.top, 12)

            Button(action: onImport) { Text("Import from Files") }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 48)
                .padding(.top, 36)
                .disabled(isImporting)
            Button(action: onFinderHelp) {
                Text("How to copy with Finder")
                    .font(.system(size: 15))
                    .underline()
                    .foregroundStyle(Theme.ink)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            Spacer()
            MetaText("FLAC · ALAC · WAV · AIFF · MP3 · AAC", size: 9.5, tracking: 1)
                .padding(.bottom, 16)
        }
    }
}

struct FinderHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let steps = [
        "Connect your iPhone to your Mac with a cable.",
        "In Finder, select your iPhone in the sidebar, then click Files.",
        "Drag album folders onto Closure. Covers, lyrics and cue sheets can come along.",
        "Open Closure. It moves the music into your library and tells you what it imported.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Copy with Finder")
                .font(Theme.serif(36))
                .foregroundStyle(Theme.ink)
                .padding(.top, 28)
            MetaText("Mac · USB cable", size: 10)
                .padding(.top, 6)
                .padding(.bottom, 20)
            Hairline()
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(String(format: "%02d", index + 1))
                        .font(Theme.mono(12, medium: false))
                        .foregroundStyle(Theme.muted)
                    Text(step)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 16)
                Hairline()
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.bottom, 12)
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .presentationDetents([.large])
        .presentationBackground(Theme.paper)
        .presentationDragIndicator(.visible)
    }
}

/// What the last import did: imported, left in place, failed.
struct ImportResultView: View {
    let summary: ImportSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let report = summary.report
        VStack(alignment: .leading, spacing: 0) {
            Text(report.audioFiles > 0 ? "Imported" : "Nothing imported")
                .font(Theme.serif(36))
                .foregroundStyle(Theme.ink)
                .padding(.top, 28)
            MetaText("From \(summary.source)", size: 10)
                .padding(.top, 6)
                .padding(.bottom, 20)
            Hairline()
            row("Tracks", report.audioFiles)
            row("Covers & lyrics", report.companionFiles)
            if summary.source == "Finder" {
                row("Left in Documents", report.leftInPlace.count,
                    note: names(report.leftInPlace, reason: "not a music file"))
            }
            row("Failed", report.failed.count, note: names(report.failed, reason: "left where it was"))
            Spacer(minLength: 20)
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.bottom, 12)
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.paper)
        .presentationDragIndicator(.visible)
    }

    private func row(_ label: String, _ value: Int, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MetaText(label, size: 10)
                Spacer()
                Text("\(value)")
                    .font(Theme.mono(15))
                    .foregroundStyle(Theme.ink)
            }
            if let note, value > 0 {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 15)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
    }

    private func names(_ items: [String], reason: String) -> String? {
        guard !items.isEmpty else { return nil }
        let shown = items.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return items.count > 2 ? "\(shown) and \(items.count - 2) more — \(reason)" : "\(shown) — \(reason)"
    }
}

struct SearchView: View {
    let onOpen: (LibraryRoute) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Albums, artists, tracks", text: $query)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Theme.paper2, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 24)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let albums = matchingAlbums
                    let tracks = matchingTracks
                    if !albums.isEmpty {
                        MetaText("Albums", size: 10).padding(.top, 24).padding(.bottom, 8)
                        Hairline()
                        ForEach(albums) { album in
                            Button { onOpen(.album(album.id)) } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(request: album.artworkRequest, title: album.title, pixelSize: 160)
                                        .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title).font(.system(size: 16)).foregroundStyle(Theme.ink).lineLimit(1)
                                        Text(album.artist).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Hairline()
                        }
                    }
                    if !tracks.isEmpty {
                        MetaText("Tracks", size: 10).padding(.top, 24).padding(.bottom, 8)
                        Hairline()
                        ForEach(tracks, id: \.track.id) { item in
                            Button {
                                player.play(item.album.tracks, from: item.index, context: item.album.title)
                                dismiss()
                            } label: {
                                TrackRow(number: nil, title: item.track.title,
                                         subtitle: "\(item.track.artist) — \(item.album.title)",
                                         duration: item.track.duration,
                                         isCurrent: player.currentTrack?.id == item.track.id)
                            }
                            .buttonStyle(.plain)
                            Hairline()
                        }
                    }
                    if !query.isEmpty && albums.isEmpty && tracks.isEmpty {
                        Text("No results for \u{201C}\(query)\u{201D}")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 32)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .presentationDetents([.large])
        .presentationBackground(Theme.paper)
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
    }

    private func matches(_ text: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    private var matchingAlbums: [Album] {
        guard !query.isEmpty else { return [] }
        return Array(library.albums.filter { matches($0.title) || matches($0.artist) }.prefix(20))
    }

    private var matchingTracks: [(track: Track, album: Album, index: Int)] {
        guard !query.isEmpty else { return [] }
        var results: [(Track, Album, Int)] = []
        for album in library.albums {
            for (index, track) in album.tracks.enumerated() where matches(track.title) || matches(track.artist) {
                results.append((track, album, index))
                if results.count == 50 { return results }
            }
        }
        return results
    }
}
