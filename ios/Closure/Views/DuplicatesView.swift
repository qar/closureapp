import SwiftUI

/// Library files with exactly the same content (SHA-256). One copy of each is kept; the
/// others move to Recently Deleted, where they stay restorable for 30 days.
struct DuplicatesView: View {
    @Environment(LibraryStore.self) private var library
    /// The copy to keep, by group (keyed by the group's first path).
    @State private var keep: [String: String] = [:]
    @State private var confirming = false

    var body: some View {
        let groups = library.duplicateGroups
        let extra = extraCopies(groups)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackBar(title: "Library Info")
                Text("Duplicates")
                    .font(Theme.serif(36))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                Text("These files have exactly the same content. Keep one copy of each; the others move to Recently Deleted for 30 days.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                if groups.isEmpty {
                    Text("No duplicates.")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 32)
                } else {
                    TextAction(title: "Remove \(extra.count) Extra Cop\(extra.count == 1 ? "y" : "ies")", systemImage: "trash") {
                        confirming = true
                    }
                    .padding(.top, 10)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.self) { group in
                            groupView(group)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.horizontalMargin)
            .padding(.bottom, 32)
        }
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Move \(extra.count) extra cop\(extra.count == 1 ? "y" : "ies") to Recently Deleted?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) {
                Task { await library.moveFilesToTrash(extra) }
            }
        } message: {
            Text("One copy of each file stays in the library.")
        }
    }

    private func groupView(_ group: [String]) -> some View {
        let track = library.albums.lazy.flatMap(\.tracks).first { group.contains($0.id) }
        let kept = kept(in: group)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track?.title ?? (group[0] as NSString).lastPathComponent)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                MetaText([track?.artist, "\(group.count) copies", track.map { ByteCountFormatter.string(fromByteCount: $0.fileSize, countStyle: .file) }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), size: 9.5, tracking: 0.8)
            }
            .padding(.top, 28)
            .padding(.bottom, 10)
            Hairline()
            // The default keeper first; the order stays put when the user picks another.
            let first = DuplicatesViewKeep.pick(group)
            ForEach([first] + group.filter { $0 != first }, id: \.self) { path in
                Button { keep[group[0]] = path } label: {
                    HStack(spacing: 12) {
                        Image(systemName: path == kept ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(path == kept ? Theme.ink : Theme.muted.opacity(0.6))
                        Text(path)
                            .font(.system(size: 13))
                            .foregroundStyle(path == kept ? Theme.ink : Theme.muted)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        MetaText(path == kept ? "Keep" : "Remove", size: 9.5, color: path == kept ? Theme.ink : Theme.muted)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(path), \(path == kept ? "keep" : "remove")")
                .accessibilityHint("Keep this copy")
                Hairline()
            }
        }
    }

    private func kept(in group: [String]) -> String {
        if let chosen = keep[group[0]], group.contains(chosen) { return chosen }
        return DuplicatesViewKeep.pick(group)
    }

    private func extraCopies(_ groups: [[String]]) -> [String] {
        groups.flatMap { group in
            let kept = kept(in: group)
            return group.filter { $0 != kept }
        }
    }
}
