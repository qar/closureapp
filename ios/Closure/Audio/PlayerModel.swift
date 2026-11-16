import Foundation
import MediaPlayer
import Observation

/// Main-thread face of the playback engine for the UI, the lock screen and
/// Control Center. It holds the queue; the engine holds the audio.
@MainActor
@Observable
final class PlayerModel {
    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int = -1
    private(set) var isPlaying = false
    private(set) var lastError: String?
    private(set) var repeatMode: CLSRepeatMode = .all
    /// Where the queue came from, e.g. an album title. Shown as "Playing from".
    private(set) var contextTitle = ""

    var currentTrack: Track? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    @ObservationIgnored private let engine = CLSEngine()
    @ObservationIgnored private let session = AudioSessionController()
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingArtwork: (key: String, artwork: MPMediaItemArtwork)?
    /// Set after a relaunch: where to start when the user presses play. The engine and
    /// the audio session stay untouched until then, so opening Closure never stops
    /// another app's audio.
    private(set) var pendingPosition: Double?
    @ObservationIgnored private let stateURL: URL

    init(stateURL: URL = PlaybackState.appURL) {
        self.stateURL = stateURL
        engine.setRepeatMode(repeatMode)
        engine.eventHandler = { [weak self] type, index, message in
            MainActor.assumeIsolated { self?.handle(type, index: index, message: message) }
        }
        wireSession()
        wireRemoteCommands()
    }

    /// Engine status for diagnostics and the progress bar. Cheap: it reads atomics and
    /// a short list under one lock. Views poll it only while they are on screen.
    var status: CLSEngineStatus { engine.status }

    /// Position and duration for progress bars, also before a restored queue is loaded.
    var progress: (position: Double, duration: Double) {
        if let pendingPosition { return (pendingPosition, currentTrack?.duration ?? 0) }
        let status = engine.status
        return (status.positionSeconds, status.durationSeconds)
    }

    var routeDescription: String { session.routeDescription }
    var hardwareSampleRate: Double { session.sampleRate }

    // MARK: - Commands

    /// Plays `tracks` (normally one album) from `index`. The hardware rate is chosen
    /// once per queue, from the starting track, so album playback stays gapless.
    /// With `shuffled`, the queue order is shuffled and playback starts at its first track.
    func play(_ tracks: [Track], from index: Int, context: String = "", shuffled: Bool = false) {
        guard tracks.indices.contains(index) else { return }
        let ordered = shuffled ? tracks.shuffled() : tracks
        queue = ordered
        contextTitle = context
        start(at: shuffled ? 0 : index, position: 0)
    }

    /// Loads the queue into the engine and plays from `position` in track `index`.
    private func start(at index: Int, position: Double) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        pendingPosition = nil
        lastError = nil
        let source = CLSEngine.probe(queue[index].url.path)
        do {
            let rate = try session.activate(preferredSampleRate: source.sampleRate)
            try engine.setOutputSampleRate(rate)
            engine.setQueue(queue.map(\.url.path), start: index)
            // Before play, so the start of the track is never heard.
            if position > 0 { engine.seek(to: position) }
            try engine.play()
            isPlaying = true
        } catch {
            lastError = error.localizedDescription
            isPlaying = false
        }
        updateNowPlaying()
        saveState()
    }

    // MARK: - Saved state

    /// Puts back the queue and position saved last time, paused. Does nothing when
    /// something is already playing or nothing usable was saved.
    func restore(from albums: [Album]) {
        guard queue.isEmpty, let saved = PlaybackState.load(from: stateURL) else { return }
        let library = Dictionary(albums.flatMap(\.tracks).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let restored = saved.restore(from: library) else { return }
        queue = restored.tracks
        currentIndex = restored.index
        pendingPosition = restored.position
        contextTitle = saved.context
        if let mode = CLSRepeatMode(rawValue: saved.repeatMode) { setRepeatMode(mode) }
        print(String(format: "[Closure] restored %d track(s), track %d at %.0f s", queue.count, currentIndex + 1, restored.position))
    }

    /// Saves the queue and position. Cheap; called on every state change and when the
    /// app leaves the foreground.
    func saveState() {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else { return }
        let position = pendingPosition ?? engine.status.positionSeconds
        PlaybackState(trackIDs: queue.map(\.id), index: currentIndex, position: position,
                      context: contextTitle, repeatMode: repeatMode.rawValue).save(to: stateURL)
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        guard pendingPosition == nil else { return }
        engine.pause()
        isPlaying = false
        updateNowPlaying()
        saveState()
    }

    func resume() {
        guard !queue.isEmpty else { return }
        if let pendingPosition {
            start(at: currentIndex, position: pendingPosition)
            return
        }
        do {
            try session.activate()
            syncOutputRate()
            try engine.play()
            isPlaying = true
        } catch {
            lastError = error.localizedDescription
        }
        updateNowPlaying()
    }

    func next() {
        if pendingPosition != nil {
            let next = currentIndex + 1
            moveRestored(to: next < queue.count ? next : (repeatMode == .all ? 0 : currentIndex))
            return
        }
        engine.next()
        refreshIndex()
    }

    /// Jumps to a track in the current queue.
    func playQueueIndex(_ index: Int) {
        guard queue.indices.contains(index) else { return }
        if pendingPosition != nil {
            start(at: index, position: 0)
            return
        }
        engine.play(index)
        currentIndex = index
        isPlaying = true
        updateNowPlaying()
    }

    func previous() {
        if let pendingPosition {
            // Like the engine: past the first seconds, go back to the start of the track.
            moveRestored(to: pendingPosition > 3 ? currentIndex : max(0, currentIndex - 1))
            return
        }
        engine.previous()
        refreshIndex()
    }

    func seek(to seconds: Double) {
        if pendingPosition != nil {
            pendingPosition = max(0, seconds)
            saveState()
            return
        }
        engine.seek(to: seconds)
        updateNowPlaying()
        saveState()
    }

    /// Next and previous before the restored queue is loaded: move without playing.
    private func moveRestored(to index: Int) {
        currentIndex = index
        pendingPosition = 0
        saveState()
    }

    func setRepeatMode(_ mode: CLSRepeatMode) {
        repeatMode = mode
        engine.setRepeatMode(mode)
        saveState()
    }

    // MARK: - Engine and session events

    private func handle(_ type: CLSEngineEventType, index: Int, message: String) {
        switch type {
        case .trackChanged:
            currentIndex = index
            saveState()
        case .ended:
            isPlaying = false
            saveState()
        case .error:
            let name = queue.indices.contains(index) ? queue[index].title : "track \(index + 1)"
            lastError = "\(name): \(message)"
        @unknown default:
            break
        }
        updateNowPlaying()
    }

    private func refreshIndex() {
        let status = engine.status
        if status.trackIndex >= 0 { currentIndex = status.trackIndex }
        updateNowPlaying()
    }

    /// Re-opens the output when the hardware rate changed (e.g. a new route).
    private func syncOutputRate() {
        let hardwareRate = session.sampleRate
        if abs(engine.status.outputSampleRate - hardwareRate) > 0.5 {
            try? engine.setOutputSampleRate(hardwareRate)
        }
    }

    private func wireSession() {
        session.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            resumeAfterInterruption = isPlaying
            pause()
        }
        session.onInterruptionEnded = { [weak self] shouldResume in
            guard let self else { return }
            if shouldResume && resumeAfterInterruption { resume() }
            resumeAfterInterruption = false
        }
        session.onOutputLost = { [weak self] in
            // Never move playback to the speaker on its own.
            self?.pause()
        }
        session.onRouteChanged = { [weak self] in
            self?.syncOutputRate()
        }
        session.onMediaServicesReset = { [weak self] in
            guard let self else { return }
            // The output unit is gone. Rebuild it at the current hardware rate.
            // The engine resumes on its own if it was playing.
            engine.resetOutput()
            if (try? session.activate()) != nil {
                try? engine.setOutputSampleRate(session.sampleRate)
            }
        }
    }

    // MARK: - Lock screen and Control Center

    private func wireRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    /// The system extrapolates elapsed time from the rate, so this runs only on
    /// state changes, never on a timer.
    private func updateNowPlaying() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let status = engine.status
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: status.durationSeconds > 0 ? status.durationSeconds : track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: status.positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: currentIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
        ]
        if !track.artist.isEmpty { info[MPMediaItemPropertyArtist] = track.artist }
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        if let cached = nowPlayingArtwork, cached.key == track.albumKey {
            info[MPMediaItemPropertyArtwork] = cached.artwork
        } else {
            loadArtwork(for: track)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for track: Track) {
        artworkTask?.cancel()
        let request = track.artworkRequest
        artworkTask = Task { [weak self] in
            guard let image = await ArtworkStore.shared.image(for: request, pixelSize: 600),
                  !Task.isCancelled, let self, self.currentTrack?.albumKey == track.albumKey else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.nowPlayingArtwork = (track.albumKey, artwork)
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
