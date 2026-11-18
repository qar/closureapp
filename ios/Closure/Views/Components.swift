import SwiftUI
import UIKit

/// Square album artwork with a typographic placeholder while loading or when none exists.
struct ArtworkView: View {
    let request: ArtworkStore.Request
    let title: String
    var cornerRadius: CGFloat = 2
    var pixelSize = 720

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: "\(request.key)|\(request.stamp)") {
                image = await ArtworkStore.shared.image(for: request, pixelSize: pixelSize)
            }
            .accessibilityHidden(true)
    }

    /// No artwork: paper with three hairline circles. It does not repeat the title,
    /// which is always shown next to the cover.
    private var placeholder: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            ZStack {
                Theme.paper2
                ForEach([0.74, 0.48, 0.22], id: \.self) { ratio in
                    Circle()
                        .stroke(Theme.ink.opacity(0.12), lineWidth: 1)
                        .frame(width: side * ratio, height: side * ratio)
                }
            }
        }
    }
}

/// Persistent bar above the home indicator. The hairline on top shows progress.
struct MiniPlayer: View {
    @Environment(PlayerModel.self) private var player
    let onOpen: () -> Void

    var body: some View {
        if let track = player.currentTrack {
            VStack(spacing: 0) {
                progressLine
                HStack(spacing: 12) {
                    Button(action: onOpen) {
                        HStack(spacing: 12) {
                            ArtworkView(request: track.artworkRequest, title: track.album, pixelSize: 160)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Text(track.artist.isEmpty ? track.album : track.artist)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Now playing: \(track.title)")

                    IconButton(systemName: player.isPlaying ? "pause.fill" : "play.fill", size: 22,
                               label: player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                    IconButton(systemName: "forward.end.fill", size: 18, label: "Next") { player.next() }
                }
                .padding(.leading, 20)
                .padding(.trailing, 8)
                .padding(.vertical, 12)
            }
            .background(Theme.paper2.ignoresSafeArea(edges: .bottom))
        }
    }

    /// Updates once a second, and only while playing.
    private var progressLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let progress = player.progress
            let fraction = progress.duration > 0 ? min(1, progress.position / progress.duration) : 0
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.ink.opacity(0.12))
                    Rectangle().fill(Theme.ink).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 1.5)
        }
    }
}

/// One row in a track list: number (or a playing marker), title, optional subtitle, duration.
struct TrackRow: View {
    let number: Int?
    let title: String
    var subtitle: String?
    let duration: Double
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if isCurrent {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                } else if let number {
                    Text(String(format: "%02d", number))
                        .font(Theme.mono(12, medium: false))
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(formatTime(duration))
                .font(Theme.mono(12, medium: false))
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, subtitle == nil ? 17 : 11)
        .contentShape(Rectangle())
    }
}

/// Quiet action: small monospaced label with an icon and a thin underline
/// (album header option 1, "Text actions"). The hit area is 44 pt tall.
struct TextAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                    MetaText(title, size: 11, color: Theme.ink)
                }
                Rectangle().fill(Theme.ink).frame(height: 1)
            }
            .fixedSize()
            .foregroundStyle(Theme.ink)
            .frame(minHeight: 44, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// "‹ LIBRARY" back control used by pushed screens.
struct BackBar<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Button { dismiss() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    MetaText(title, color: Theme.ink)
                }
                .foregroundStyle(Theme.ink)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to \(title)")
            Spacer()
            trailing()
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
    }
}

extension BackBar where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// The "…" button used on Now Playing, in Google Drive and on the album page.
struct MoreMenu<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// The context menu for tracks or an album: Play Next, Play Last (as in Apple Music),
/// Favorites for a single track, and Add to Playlist. A light haptic confirms changes
/// the screen does not show.
struct TrackMenuItems: View {
    let tracks: [Track]
    let context: String
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(\.addToPlaylist) private var addToPlaylist

    var body: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            player.playNext(tracks, context: context)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
            player.playLast(tracks, context: context)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        Divider()
        if tracks.count == 1, let track = tracks.first {
            let favorite = library.isFavorite(track)
            Button(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "heart.slash" : "heart") {
                Task { await library.toggleFavorite(track) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        if let addToPlaylist {
            Button("Add to Playlist…", systemImage: "text.badge.plus") { addToPlaylist(tracks) }
        }
    }
}

/// A label above a plain text field with a hairline under it (Edit Album, Find Info).
struct UnderlineField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var keyboard: UIKeyboardType = .default
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MetaText(label, size: 10)
            TextField(placeholder, text: $text)
                .font(.system(size: 17))
                .foregroundStyle(Theme.ink)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .numberPad ? .never : .words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .padding(.vertical, 6)
            Hairline()
        }
    }
}
