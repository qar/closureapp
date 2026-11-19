import SwiftUI

/// The library as it is stored: every folder with audio in it, whatever the tags say.
/// Opened from Library Info.
struct FoldersView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let folders = Dictionary(grouping: library.allTracks, by: \.folder)
            .map { (path: $0.key, tracks: $0.value.count) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackBar(title: "Library Info")
                VStack(alignment: .leading, spacing: 0) {
                    Text("Folders")
                        .font(Theme.serif(36))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your music as it is stored, folder by folder, whatever the tags say.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 6)
                    HStack {
                        MetaText("\(folders.count) folders", size: 10)
                        Spacer()
                        MetaText("A–Z", size: 10)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 10)
                    LazyVStack(spacing: 0) {
                        Hairline()
                        ForEach(folders, id: \.path) { folder in
                            NavigationLink(value: LibraryRoute.folder(folder.path)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(Self.name(folder.path))
                                            .font(.system(size: 17))
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                        MetaText("\(folder.tracks) track\(folder.tracks == 1 ? "" : "s")\(Self.parent(folder.path))",
                                                 size: 9.5, tracking: 1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.muted)
                                }
                                .padding(.vertical, 14)
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
    }

    private static func name(_ folder: String) -> String {
        folder.split(separator: "/").last.map(String.init) ?? "Library"
    }

    /// " · Box Set" for "Box Set/CD1".
    private static func parent(_ folder: String) -> String {
        let parts = folder.split(separator: "/").dropLast()
        return parts.isEmpty ? "" : " · " + parts.joined(separator: "/")
    }
}
