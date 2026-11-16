import SwiftUI

/// Compact bar above the bottom edge. It shows no progress, so it needs no timer.
struct NowPlayingBar: View {
    @Environment(PlayerModel.self) private var player
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(player.currentTrack?.artist ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct NowPlayingView: View {
    @Environment(PlayerModel.self) private var player
    @State private var scrubPosition: Double?

    var body: some View {
        // Polls the engine twice a second, and only while this sheet is on screen.
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let status = player.status
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.currentTrack?.title ?? "Nothing playing")
                            .font(.title2.weight(.semibold))
                        Text([player.currentTrack?.artist, player.currentTrack?.album]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    progress(status)
                    controls
                }

                if let error = player.lastError {
                    Section("Error") {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section("Signal path") {
                    LabeledContent("File", value: player.currentTrack?.formatSummary ?? "–")
                    LabeledContent("Hardware rate", value: rate(player.hardwareSampleRate))
                    LabeledContent("Engine output", value: rate(status.outputSampleRate))
                    LabeledContent("Rate conversion", value: conversion(status))
                    LabeledContent("Digital gain", value: "Unity (system volume)")
                    LabeledContent("Route", value: player.routeDescription)
                    LabeledContent("Buffered", value: String(format: "%.1f s", status.bufferedSeconds))
                    LabeledContent("Underruns", value: "\(status.underruns)")
                }
            }
        }
    }

    private func progress(_ status: CLSEngineStatus) -> some View {
        let duration = max(status.durationSeconds, 0.01)
        let shown = scrubPosition ?? status.positionSeconds
        return VStack(spacing: 4) {
            Slider(value: Binding(get: { min(shown, duration) },
                                  set: { scrubPosition = $0 }),
                   in: 0...duration) { editing in
                if !editing, let target = scrubPosition {
                    player.seek(to: target)
                    scrubPosition = nil
                }
            }
            HStack {
                Text(formatTime(shown))
                Spacer()
                Text(formatTime(status.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack {
            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? .secondary : .primary)
            }
            .accessibilityLabel("Repeat")
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.largeTitle)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
            Spacer()
            // Keeps the transport buttons centred.
            Image(systemName: "repeat").hidden()
        }
        .font(.title2)
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }

    private func rate(_ value: Double) -> String {
        value > 0 ? String(format: "%g kHz", value / 1000) : "–"
    }

    private func conversion(_ status: CLSEngineStatus) -> String {
        if status.outputSampleRate <= 0 { return "–" }
        if status.resampling {
            return String(format: "In app: %g → %g kHz", status.sourceSampleRate / 1000, status.outputSampleRate / 1000)
        }
        return "None"
    }
}
