import SwiftUI

/// Files that need attention: ones Closure cannot read, and ones that went missing.
struct FileProblemsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var confirmingRemove = false

    var body: some View {
        let unreadable = library.unreadableTracks
        let missing = library.missingFiles
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackBar(title: "Library Info")
                VStack(alignment: .leading, spacing: 0) {
                    Text("File Problems")
                        .font(Theme.serif(36))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    if unreadable.isEmpty && missing.isEmpty {
                        Text("All files in your library can be read.")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 24)
                    }

                    if !unreadable.isEmpty {
                        section("Can't be read", count: unreadable.count,
                                note: "These files are damaged or in a format Closure does not play. Import a good copy, then remove these.")
                        TextAction(title: "Move to Recently Deleted", systemImage: "trash") { confirmingRemove = true }
                            .padding(.top, 4)
                        rows(unreadable.map { ($0.id, $0.title, $0.id) })
                    }

                    if !missing.isEmpty {
                        section("Missing", count: missing.count,
                                note: "These tracks were in your library, but their files are gone. Import them again to bring them back.")
                        TextAction(title: "Clear List", systemImage: "xmark") { library.clearMissingFiles() }
                            .padding(.top, 4)
                        rows(missing.map { ($0.id, $0.title, [$0.artist, $0.album].filter { !$0.isEmpty }.joined(separator: " — ")) })
                    }
                }
                .padding(.horizontal, Theme.horizontalMargin)
            }
            .padding(.bottom, 32)
        }
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Move \(unreadable.count) unreadable file\(unreadable.count == 1 ? "" : "s") to Recently Deleted?",
                            isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) { Task { await library.moveUnreadableToTrash() } }
        } message: {
            Text("You can restore them for 30 days.")
        }
    }

    private func section(_ title: String, count: Int, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                MetaText(title, size: 10, color: Theme.ink)
                Spacer()
                MetaText("\(count)", size: 10)
            }
            .accessibilityAddTraits(.isHeader)
            Text(note)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 32)
    }

    private func rows(_ items: [(id: String, title: String, detail: String)]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Hairline()
            ForEach(items, id: \.id) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Hairline()
            }
        }
        .padding(.top, 10)
    }
}
