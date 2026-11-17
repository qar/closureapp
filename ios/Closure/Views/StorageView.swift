import SwiftUI

/// Where the space goes: the library against the whole iPhone, then each album by size.
struct StorageView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let albums = library.albums.sorted { $0.byteCount > $1.byteCount }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackBar(title: "Library")
                VStack(alignment: .leading, spacing: 0) {
                    Text("Storage")
                        .font(Theme.serif(36))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    if let storage = library.storage {
                        usage(storage).padding(.top, 24)
                    } else {
                        ProgressView().tint(Theme.ink).padding(.top, 24)
                    }
                    Text("Your music is stored only on this iPhone and is not part of its iCloud backup. Keep your original files until Closure can back up your library.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)

                    HStack {
                        MetaText("Albums by size", size: 10, color: Theme.ink)
                        Spacer()
                        MetaText("\(albums.count)", size: 10)
                    }
                    .padding(.top, 36)
                    .padding(.bottom, 10)
                    LazyVStack(spacing: 0) {
                        Hairline()
                        ForEach(albums) { album in
                            NavigationLink(value: LibraryRoute.album(album.id)) {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(album.title)
                                            .font(.system(size: 16))
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                        MetaText("\(album.artist) · \(album.tracks.count) track\(album.tracks.count == 1 ? "" : "s")",
                                                 size: 9.5, tracking: 0.8)
                                    }
                                    Spacer(minLength: 8)
                                    Text(ByteCountFormatter.string(fromByteCount: album.byteCount, countStyle: .file))
                                        .font(Theme.mono(13, medium: false))
                                        .foregroundStyle(Theme.ink)
                                }
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Hairline()
                        }
                    }
                }
                .padding(.horizontal, Theme.horizontalMargin)
            }
            .padding(.bottom, 32)
        }
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { library.measureStorage() }
    }

    /// A flat bar (music, everything else, free) and the three figures under it.
    private func usage(_ storage: StorageSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let shares = storage.shares {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        // A small library still shows as a mark on the bar.
                        Rectangle().fill(Theme.ink)
                            .frame(width: storage.music > 0 ? max(2, proxy.size.width * shares.music) : 0)
                        Rectangle().fill(Theme.muted.opacity(0.45)).frame(width: proxy.size.width * shares.other)
                        Rectangle().fill(Theme.hairline)
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            HStack(alignment: .top) {
                figure("Music", storage.music, swatch: Theme.ink)
                figure("Other", otherBytes(storage), swatch: Theme.muted.opacity(0.45))
                figure("Free", storage.free, swatch: Theme.hairline)
            }
            .padding(.top, 14)
            if storage.recentlyDeleted > 0 {
                Text("Recently Deleted holds \(ByteCountFormatter.string(fromByteCount: storage.recentlyDeleted, countStyle: .file)), counted in Other. It is freed when items expire after 30 days or when you delete them there.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
    }

    private func otherBytes(_ storage: StorageSummary) -> Int64? {
        guard let capacity = storage.capacity, let free = storage.free else { return nil }
        return max(0, capacity - free - storage.music)
    }

    private func figure(_ label: String, _ bytes: Int64?, swatch: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Rectangle().fill(swatch).frame(width: 8, height: 8)
                MetaText(label, size: 9.5)
            }
            Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "–")
                .font(Theme.mono(15))
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
