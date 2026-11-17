import SwiftUI

/// Lyrics in place of the cover on Now Playing. Timed lyrics follow the music: the
/// line being sung is in ink, the rest are faint, and tapping a line plays from it.
/// Tapping anywhere else goes back to the cover.
struct LyricsView: View {
    let lyrics: Lyrics?
    let isLoading: Bool
    /// Looks the track up on LRCLIB; returns whether lyrics were found.
    let onFind: () async -> Bool
    let onClose: () -> Void
    @State private var finding = false
    @State private var notFound = false
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Group {
            if let lyrics {
                if lyrics.isSynced {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        lines(lyrics, current: lyrics.index(at: player.progress.position))
                    }
                } else {
                    lines(lyrics, current: nil)
                }
            } else {
                VStack(spacing: 8) {
                    MetaText(isLoading ? "Loading lyrics" : finding ? "Searching LRCLIB" : notFound ? "No lyrics found online" : "No lyrics",
                             size: 10.5, color: Theme.ink)
                    if !isLoading && !finding {
                        Text("Lyrics come from the file's tags or a .lrc file imported with it. You can also look this track up on LRCLIB.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                        if !notFound {
                            TextAction(title: "Find Lyrics Online", systemImage: "magnifyingglass") {
                                finding = true
                                Task {
                                    notFound = !(await onFind())
                                    finding = false
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .accessibilityAction(named: "Show Cover", onClose)
    }

    private func lines(_ lyrics: Lyrics, current: Int?) -> some View {
        ScrollViewReader { reader in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: lyrics.isSynced ? 16 : 6) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        lineView(line, isCurrent: index == current, synced: lyrics.isSynced)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room for the first and last lines to reach the middle.
                .padding(.vertical, lyrics.isSynced ? 120 : 16)
            }
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                       .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .onChange(of: current) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.35)) { reader.scrollTo(index, anchor: .center) }
            }
            .onAppear {
                if let current { reader.scrollTo(current, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: Lyrics.Line, isCurrent: Bool, synced: Bool) -> some View {
        if synced, let time = line.time {
            Button { player.seek(to: time) } label: {
                Text(line.text)
                    .font(Theme.serif(26, relativeTo: .title2))
                    .foregroundStyle(isCurrent ? Theme.ink : Theme.muted.opacity(0.55))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .animation(.easeOut(duration: 0.2), value: isCurrent)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Plays from this line")
        } else {
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 17))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
