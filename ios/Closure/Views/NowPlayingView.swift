
import SwiftUI

struct NowPlayingView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var showingSignalPath = false
    @State private var showingQueue = false
    /// The play mode just picked, named for a moment in place of the format line.
    @State private var modeNotice: PlayMode?
    /// Lyrics replace the cover; a tap on either switches.
    @State private var showingLyrics = false
    @State private var lyrics: Lyrics?
    @State private var lyricsLoading = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let track = player.currentTrack {
                // The same square either way, so nothing below moves.
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if showingLyrics {
                            LyricsView(lyrics: lyrics, isLoading: lyricsLoading) { showingLyrics = false }
                        } else {
                            ArtworkView(request: track.artworkRequest, title: track.album, pixelSize: 1100)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.ink.opacity(0.1), lineWidth: 1))
                                .onTapGesture { showingLyrics = true }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel("Cover. Shows lyrics")
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .task(id: track.id) {
                        lyrics = nil
                        lyricsLoading = true
                        lyrics = await LyricsLoader.load(for: track.url)
                        lyricsLoading = false
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title)
                        .font(Theme.serif(44))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.55)
                    Text(subtitle(track))
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 24)

                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let progress = player.progress
                    ProgressScrubber(position: progress.position, duration: progress.duration) { seconds in
                        player.seek(to: seconds)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)

                transport
                    .padding(.top, 22)

                Spacer(minLength: 12)
                bottomBar(track)
            } else {
                Spacer()
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .sheet(isPresented: $showingSignalPath) {
            SignalPathView()
                .presentationDetents([.fraction(0.8), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.paper)
        }
        .sheet(isPresented: $showingQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.paper)
        }
#if DEBUG
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if let flag = arguments.firstIndex(of: "-ClosureScreen"), flag + 1 < arguments.count {
                showingSignalPath = arguments[flag + 1] == "signal"
                showingQueue = arguments[flag + 1] == "queue"
                showingLyrics = arguments[flag + 1] == "lyrics"
            }
            // -ClosurePlayMode <mode>: switch to it after 2 s, as a tap would, for screenshots.
            if let modeFlag = arguments.firstIndex(of: "-ClosurePlayMode"), modeFlag + 1 < arguments.count,
               let raw = Int(arguments[modeFlag + 1]), let mode = PlayMode(rawValue: raw) {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    player.setPlayMode(mode)
                    modeNotice = mode
                }
            }
            // -ClosureShuffle: turn shuffle on after 3 s and log the order and position.
            if arguments.contains("-ClosureShuffle") {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    let before = player.progress.position
                    let track = player.currentTrack?.title ?? "?"
                    player.setShuffle(true)
                    try? await Task.sleep(for: .seconds(1))
                    print(String(format: "[Closure] shuffle on: %@ %.2f s -> %@ %.2f s; queue %@", track, before,
                                 player.currentTrack?.title ?? "?", player.progress.position,
                                 player.queue.map(\.title).joined(separator: ", ")))
                    try? await Task.sleep(for: .seconds(1))
                    player.setShuffle(false)
                    try? await Task.sleep(for: .seconds(1))
                    print(String(format: "[Closure] shuffle off: %@ at %.2f s, index %d; queue %@", player.currentTrack?.title ?? "?",
                                 player.progress.position, player.currentIndex, player.queue.map(\.title).joined(separator: ", ")))
                    player.setShuffle(true)
                }
            }
        }
#endif
    }

    private var topBar: some View {
        HStack {
            IconButton(systemName: "chevron.down", size: 20, weight: .semibold, label: "Close") { dismiss() }
            Spacer()
            MetaText(player.contextTitle.isEmpty ? "Now playing" : "Playing from  \(player.contextTitle)")
            Spacer()
            Menu {
                Picker("Play Mode", selection: Binding(get: { player.playMode }, set: { player.setPlayMode($0) })) {
                    ForEach(PlayMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 10)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            Spacer()
            transportButton("backward.end.fill", size: 28, label: "Previous") { player.previous() }
            Spacer()
            transportButton(player.isPlaying ? "pause.fill" : "play.fill", size: 46,
                            label: player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
            Spacer()
            transportButton("forward.end.fill", size: 28, label: "Next") { player.next() }
            Spacer()
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(Theme.ink)
                .frame(width: 72, height: 72)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func bottomBar(_ track: Track) -> some View {
        HStack {
            playModeButton
            Spacer()
            Button { showingSignalPath = true } label: {
                MetaText(modeNotice?.title ?? "\(track.shortFormat)  ·  \(player.status.resampling ? "Converted" : "No conversion")  ›",
                         color: Theme.ink, tracking: 1)
                    .contentTransition(.opacity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Signal path")
            Spacer()
            IconButton(systemName: "list.bullet", label: "Queue") { showingQueue = true }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// Shows the current play mode; each tap moves to the next one and names it.
    private var playModeButton: some View {
        let mode = player.playMode
        return Button {
            let next = mode.next
            player.setPlayMode(next)
            withAnimation(.easeOut(duration: 0.2)) { modeNotice = next }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if modeNotice == next { withAnimation(.easeOut(duration: 0.3)) { modeNotice = nil } }
            }
        } label: {
            Image(systemName: mode.systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play mode")
        .accessibilityValue(mode.title)
        .accessibilityHint("Changes to \(mode.next.title)")
    }

    private func subtitle(_ track: Track) -> String {
        var text = track.artist.isEmpty ? "Unknown Artist" : track.artist
        if !track.album.isEmpty { text += " — \(track.album)" }
        if let year = track.year { text += ", \(year)" }
        return text
    }
}

/// Thin line with a knob. Drag to scrub; the seek happens on release.
struct ProgressScrubber: View {
    let position: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @State private var scrubbing: Double?

    var body: some View {
        let shown = scrubbing ?? position
        let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
        VStack(spacing: 10) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.ink.opacity(0.16)).frame(height: 1.5)
                    Rectangle().fill(Theme.ink).frame(width: width * fraction, height: 1.5)
                    Circle().fill(Theme.ink)
                        .frame(width: scrubbing == nil ? 10 : 16, height: scrubbing == nil ? 10 : 16)
                        .offset(x: width * fraction - (scrubbing == nil ? 5 : 8))
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        scrubbing = min(1, max(0, value.location.x / width)) * duration
                    }
                    .onEnded { _ in
                        if let target = scrubbing { onSeek(target) }
                        scrubbing = nil
                    })
            }
            .frame(height: 28)
            HStack {
                Text(formatTime(shown))
                Spacer()
                Text("−" + formatTime(max(0, duration - shown)))
            }
            .font(Theme.mono(12, medium: false))
            .foregroundStyle(Theme.muted)
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(formatTime(position)) of \(formatTime(duration))")
        .accessibilityAdjustableAction { direction in
            let step = 10.0
            onSeek(direction == .increment ? min(duration, position + step) : max(0, position - step))
        }
    }
}

/// The play queue. Tap a track to play it; swipe left to remove one; Edit to reorder.
/// The current track cannot be removed.
struct QueueView: View {
    @Environment(PlayerModel.self) private var player
    @State private var editMode: EditMode = .inactive

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Queue")
                    .font(Theme.serif(36))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(editMode.isEditing ? "Done" : "Edit") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .font(.system(size: 17, weight: editMode.isEditing ? .semibold : .regular))
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 44)
            }
            .padding(.top, 20)
            MetaText("\(player.queue.count) tracks\(player.contextTitle.isEmpty ? "" : " · from \(player.contextTitle)")", size: 10)
                .padding(.top, 2)
                .padding(.bottom, 20)
            Hairline()
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
                    Button { player.playQueueIndex(index) } label: {
                        TrackRow(number: index + 1, title: track.title, subtitle: track.artist,
                                 duration: track.duration, isCurrent: index == player.currentIndex)
                            .padding(.trailing, editMode.isEditing ? 12 : 0)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    // Full-width hairlines, as everywhere else in the app, also under the
                    // reorder handles while editing.
                    .listRowBackground(Theme.paper.overlay(alignment: .bottom) { Hairline() })
                    .listRowSeparator(.hidden)
                    // Edit only reorders, so every row lines up; removing is a swipe.
                    .deleteDisabled(editMode.isEditing || index == player.currentIndex)
                }
                .onMove { player.moveInQueue(from: $0, to: $1) }
                .onDelete { player.removeFromQueue(at: $0) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
        }
        .padding(.horizontal, Theme.horizontalMargin)
#if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-ClosureQueueEdit") { editMode = .active }
        }
#endif
    }
}

/// From the file to the output, step by step. It describes only what Closure controls,
/// and says so.
struct SignalPathView: View {
    @Environment(PlayerModel.self) private var player
    @State private var channels = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let status = player.status
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Signal path")
                        .font(Theme.serif(36))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 28)
                        .accessibilityAddTraits(.isHeader)
                    if let track = player.currentTrack {
                        MetaText("\(track.title) · \(track.artist)", size: 10)
                            .padding(.top, 6)
                        chain(track: track, status: status)
                            .padding(.top, 28)
                    }
                    Hairline().padding(.top, 8)
                    HStack(alignment: .top) {
                        footerCell("Buffer", String(format: "%.1f s", status.bufferedSeconds))
                        footerCell("Underruns", "\(status.underruns)")
                        footerCell("App DSP", "Off")
                    }
                    .padding(.vertical, 16)
                    Hairline()
                    Text("Closure passes your audio to the system unchanged. What happens after that depends on iOS and your output device.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(3)
                        .padding(.top, 16)
                }
                .padding(.horizontal, Theme.horizontalMargin)
                .padding(.bottom, 24)
            }
        }
        .task(id: player.currentTrack?.id) {
            guard let track = player.currentTrack else { return }
            channels = CLSEngine.probe(track.url.path).channels
        }
    }

    private func chain(track: Track, status: CLSEngineStatus) -> some View {
        let source = status.sourceSampleRate > 0 ? status.sourceSampleRate : track.sampleRate
        let steps: [(String, String, String)] = [
            ("Source", track.formatSummary, "\(channelsText), \(formatTime(track.duration))"),
            ("Decode", "System \(track.codec) decoder", "32-bit float"),
            ("Gain", "Unity", "Volume is set by the system"),
            ("Sample rate", "\(khz(source)) → \(khz(status.outputSampleRate))",
             status.resampling ? "Converted in Closure at mastering quality" : "No conversion"),
            ("Output", player.routeDescription, "Hardware at \(khz(player.hardwareSampleRate))"),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(index == 3 ? Theme.accent : Theme.ink)
                            .frame(width: 10, height: 10)
                            .padding(.top, 3)
                        if index < steps.count - 1 {
                            Rectangle().fill(Theme.ink.opacity(0.25)).frame(width: 1).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        MetaText(step.0, size: 10)
                        Text(step.1)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        Text(step.2)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.bottom, 20)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var channelsText: String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 0: return "–"
        default: return "\(channels) channels"
        }
    }

    private func footerCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MetaText(label, size: 9.5)
            Text(value)
                .font(Theme.mono(15))
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func khz(_ rate: Double) -> String {
        rate > 0 ? String(format: "%g kHz", rate / 1000) : "–"
    }
}
