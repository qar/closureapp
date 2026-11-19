import Foundation
import MediaPlayer

/// Values published to the lock screen and Control Center for one queue state.
struct NowPlayingSnapshot {
    var info: [String: Any]
    var playbackState: MPNowPlayingPlaybackState

    static func make(track: Track, position: Double, duration: Double, isPlaying: Bool,
                     queueIndex: Int, queueCount: Int, artwork: MPMediaItemArtwork?) -> NowPlayingSnapshot {
        let total = duration > 0 ? duration : track.duration
        let elapsed = position.isFinite ? max(0, min(position, max(0, total))) : 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist.isEmpty ? "Unknown Artist" : track.artist,
            MPMediaItemPropertyPlaybackDuration: total,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: queueIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queueCount,
        ]
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        return NowPlayingSnapshot(info: info, playbackState: isPlaying ? .playing : .paused)
    }
}
