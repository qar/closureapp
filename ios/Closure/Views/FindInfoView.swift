import SwiftUI

/// Look an album up on MusicBrainz and use a release's title, artist, year and cover.
/// Nothing is fetched until this screen opens, and nothing changes until the user
/// picks a result. Edits go to the library database; Restore Original undoes them.
struct FindInfoView: View {
    let album: Album
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var artist: String
    @State private var results: [MusicBrainz.Release]?
    @State private var searching = false
    @State private var error: String?
    @State private var picked: MusicBrainz.Release?
    @State private var applying = false
    @State private var notice: String?

    private static let client = MusicBrainzClient()

    init(album: Album) {
        self.album = album
        // Search with what the files say; an earlier edit may be the thing to fix.
        _title = State(initialValue: album.original?.title ?? album.title)
        _artist = State(initialValue: album.original?.artist ?? album.artist)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    IconButton(systemName: "xmark", size: 18, weight: .semibold, label: "Close") { dismiss() }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Find Album Info")
                        .font(Theme.serif(32))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Searches MusicBrainz with this title and artist. Covers come from the Cover Art Archive. Your files are not changed.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    UnderlineField(label: "Title", text: $title, onSubmit: search).padding(.top, 24)
                    UnderlineField(label: "Artist", text: $artist, onSubmit: search).padding(.top, 20)
                    TextAction(title: "Search", systemImage: "magnifyingglass", action: search)
                        .padding(.top, 8)
                    resultsSection.padding(.top, 20)
                }
                .padding(.horizontal, Theme.horizontalMargin)
            }
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper.ignoresSafeArea())
        .overlay {
            if applying {
                ZStack {
                    Theme.paper.opacity(0.7).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView().tint(Theme.ink)
                        MetaText("Getting the cover", size: 10)
                    }
                }
            }
        }
        .task { if results == nil { search() } }
        .confirmationDialog(picked.map { "\($0.title) — \($0.artist)" } ?? "", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                            titleVisibility: .visible, presenting: picked) { release in
            Button("Use Title, Artist, Year and Cover") { apply(release, info: true) }
            Button("Use Cover Only") { apply(release, info: false) }
        }
        .alert("Album Info", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil; dismiss() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    /// One container, so the padding applied to it is applied once.
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 0) { resultsContent }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if searching {
            ProgressView().tint(Theme.ink).frame(maxWidth: .infinity).padding(.top, 16)
        } else if let error {
            Text(error)
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
        } else if let results {
            HStack {
                MetaText("Matches", size: 10, color: Theme.ink)
                Spacer()
                MetaText("\(results.count)", size: 10)
            }
            .padding(.bottom, 10)
            if results.isEmpty {
                Text("No matches. Try a shorter title, or leave the artist empty.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
            } else {
                LazyVStack(spacing: 0) {
                    Hairline()
                    ForEach(results) { release in
                        Button { picked = release } label: { row(release) }
                            .buttonStyle(.plain)
                        Hairline()
                    }
                }
            }
        }
    }

    private func row(_ release: MusicBrainz.Release) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: release.thumbnailURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Theme.paper2
                }
            }
            .frame(width: 56, height: 56)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.ink.opacity(0.1), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(release.title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(release.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                MetaText(meta(release), size: 9.5, color: release.trackCount == album.tracks.count ? Theme.ink : Theme.muted, tracking: 0.8)
                    .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "2012 · 15 tracks · CD · GB". The track count is dark when it matches the album.
    private func meta(_ release: MusicBrainz.Release) -> String {
        var parts: [String] = []
        if let year = release.year { parts.append(String(year)) }
        if let count = release.trackCount { parts.append("\(count) track\(count == 1 ? "" : "s")") }
        if let format = release.format { parts.append(format) }
        if let country = release.country { parts.append(country) }
        return parts.joined(separator: " · ")
    }

    private func search() {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !searching else { return }
        searching = true
        error = nil
        Task {
            defer { searching = false }
            do {
                results = try await Self.client.search(title: title, artist: artist, trackCount: album.tracks.count)
#if DEBUG
                // -ClosureFindApply: use the first match, to check the whole path.
                if ProcessInfo.processInfo.arguments.contains("-ClosureFindApply"), let first = results?.first {
                    apply(first, info: true)
                }
#endif
            } catch {
                print("[Closure][MusicBrainz] search failed: \(error)")
                self.error = "MusicBrainz did not answer. Check the connection and try again."
            }
        }
    }

    private func apply(_ release: MusicBrainz.Release, info: Bool) {
        applying = true
        Task {
            let cover = await Self.client.cover(for: release)
            let current = await library.override(for: album.id)
            let original = album.original ?? Album.Original(title: album.title, artist: album.artist, year: album.year)
            // A value equal to the tags is not an edit.
            func edit<T: Equatable>(_ value: T?, _ tag: T?) -> T? { value == tag ? nil : value }
            await library.saveAlbumEdit(album.id,
                                        title: info ? edit(release.title, original.title) : current.title,
                                        artist: info ? edit(release.artist, original.artist) : current.artist,
                                        year: info ? edit(release.year, original.year) : current.year,
                                        cover: cover, removeCover: false)
            applying = false
            if cover == nil {
                notice = info ? "The info was applied. This release has no cover on the Cover Art Archive."
                              : "This release has no cover on the Cover Art Archive."
            } else {
                dismiss()
            }
        }
    }
}
