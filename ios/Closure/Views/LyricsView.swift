import SwiftUI

/// Lyrics in place of the cover on Now Playing. Timed lyrics follow the music: the
/// line being sung is in ink, the rest are faint, and tapping a line plays from a
/// second before it.
/// Tapping anywhere else goes back to the cover.
struct LyricsView: View {
    let lyrics: Lyrics?
    let isLoading: Bool
    /// Looks the track up on LRCLIB; returns whether lyrics were found.
    let onFind: () async -> Bool
    let onClose: () -> Void
    @State private var finding = false
    @State private var notFound = false
    /// True while the reader scrolls the lyrics, and for a moment after.
    @State private var followPaused = false
    @State private var resumeTask: Task<Void, Never>?
    /// Changing it scrolls back to the line being sung.
    @State private var recenter = 0

    /// After the reader scrolls away, the lyrics go back to the current line this long
    /// after the scrolling stops.
    private static let resumeDelay: Duration = .seconds(3)
    /// Tapping a line starts this much before it, so the line comes in naturally
    /// rather than mid-breath.
    static let leadIn: Double = 1
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
            .modifier(UserScrollObserver(onStart: pauseFollowing, onEnd: resumeFollowingSoon))
            .onChange(of: current) { _, index in
                guard let index, !followPaused else { return }
                withAnimation(.easeInOut(duration: 0.35)) { reader.scrollTo(index, anchor: .center) }
            }
            .onChange(of: recenter) {
                guard let current else { return }
                withAnimation(.easeInOut(duration: 0.5)) { reader.scrollTo(current, anchor: .center) }
            }
            .onAppear {
                if let current { reader.scrollTo(current, anchor: .center) }
            }
        }
    }

    private func pauseFollowing() {
        resumeTask?.cancel()
        followPaused = true
    }

    private func resumeFollowingSoon() {
        resumeTask?.cancel()
        resumeTask = Task {
            try? await Task.sleep(for: Self.resumeDelay)
            guard !Task.isCancelled else { return }
            followPaused = false
            recenter += 1
        }
    }

    @ViewBuilder
    private func lineView(_ line: Lyrics.Line, isCurrent: Bool, synced: Bool) -> some View {
        if synced, let time = line.time {
            Button {
                player.seek(to: max(0, time - Self.leadIn))
                // Playing from a line follows the lyrics again at once.
                resumeTask?.cancel()
                followPaused = false
                recenter += 1
            } label: {
                Text(line.text)
                    .font(Theme.serif(26, relativeTo: .title2))
                    .foregroundStyle(isCurrent ? Theme.ink : Theme.muted.opacity(0.55))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .animation(.easeOut(duration: 0.2), value: isCurrent)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Plays from just before this line")
        } else {
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 17))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Tells when the reader starts and stops scrolling (not scrolling done in code). iOS 18
/// reports the scroll phase; iOS 17 falls back to the drag itself.
private struct UserScrollObserver: ViewModifier {
    let onStart: () -> Void
    let onEnd: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { old, new in
                if new == .interacting {
                    onStart()
                } else if new == .idle, old == .interacting || old == .decelerating {
                    onEnd()
                }
            }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 6)
                .onChanged { _ in onStart() }
                .onEnded { _ in onEnd() })
        }
    }
}
