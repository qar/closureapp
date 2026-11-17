import SwiftUI

/// Tracks the user deleted. Each can be restored to where it was, or removed for
/// good. Items expire 30 days after deletion.
struct RecentlyDeletedView: View {
    @Environment(LibraryStore.self) private var library
    @State private var selected: TrashStore.Entry?
    @State private var confirmingEmpty = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackBar(title: "Library Info")
                Text("Recently Deleted")
                    .font(Theme.serif(36))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                Text("Items are removed permanently 30 days after you delete them.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 6)

                if library.trashEntries.isEmpty {
                    Text("Nothing here.")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 32)
                } else {
                    HStack(spacing: 24) {
                        TextAction(title: "Restore All", systemImage: "arrow.uturn.backward") {
                            Task { await library.restoreAll() }
                        }
                        TextAction(title: "Delete All", systemImage: "trash") { confirmingEmpty = true }
                    }
                    .padding(.top, 10)

                    LazyVStack(spacing: 0) {
                        Hairline()
                        ForEach(library.trashEntries) { entry in
                            Button { selected = entry } label: { row(entry) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Restore", systemImage: "arrow.uturn.backward") { Task { await library.restore(entry) } }
                                    Button("Delete Permanently", systemImage: "trash", role: .destructive) { library.deletePermanently(entry) }
                                }
                            Hairline()
                        }
                    }
                    .padding(.top, 14)
                }
            }
            .padding(.horizontal, Theme.horizontalMargin)
            .padding(.bottom, 32)
        }
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog(selected?.title ?? "", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
                            titleVisibility: .visible, presenting: selected) { entry in
            Button("Restore") { Task { await library.restore(entry) } }
            Button("Delete Permanently", role: .destructive) { library.deletePermanently(entry) }
        } message: { entry in
            Text("Restores to \(entry.originalPath)")
        }
        .confirmationDialog("Delete all \(library.trashEntries.count) items permanently?", isPresented: $confirmingEmpty,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { library.emptyTrash() }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func row(_ entry: TrashStore.Entry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text([entry.artist, entry.album].filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            MetaText(daysLeft(entry), size: 10)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Restore or delete permanently")
    }

    private func daysLeft(_ entry: TrashStore.Entry) -> String {
        let days = max(0, Int(ceil(entry.expires().timeIntervalSinceNow / 86_400)))
        return days == 1 ? "1 day" : "\(days) days"
    }
}
