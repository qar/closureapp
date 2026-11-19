import MediaPlayer
import UIKit
import XCTest

final class NowPlayingSnapshotTests: XCTestCase {
    private func track(artist: String = "Artist", album: String = "Album") -> Track {
        Track(id: "Album/01.flac", title: "Song", artist: artist, album: album, trackNumber: 1,
              duration: 180, codec: "FLAC", sampleRate: 44100, bitDepth: 16, fileSize: 1,
              modified: Date(timeIntervalSince1970: 0), year: nil, albumArtist: nil,
              discNumber: nil, composer: nil, genre: nil, isCompilation: nil)
    }

    func testPlayingSnapshotContainsLockScreenMetadataAndProgress() {
        let snapshot = NowPlayingSnapshot.make(track: track(), position: 42, duration: 180,
                                               isPlaying: true, queueIndex: 1, queueCount: 3, artwork: nil)
        XCTAssertEqual(snapshot.info[MPMediaItemPropertyTitle] as? String, "Song")
        XCTAssertEqual(snapshot.info[MPMediaItemPropertyArtist] as? String, "Artist")
        XCTAssertEqual(snapshot.info[MPMediaItemPropertyAlbumTitle] as? String, "Album")
        XCTAssertEqual(snapshot.info[MPMediaItemPropertyPlaybackDuration] as? Double, 180)
        XCTAssertEqual(snapshot.info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
        XCTAssertEqual(snapshot.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(snapshot.info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int, 1)
        XCTAssertEqual(snapshot.info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int, 3)
        XCTAssertEqual(snapshot.playbackState, .playing)
    }

    func testPausedSnapshotClampsProgressAndNamesMissingTags() {
        let snapshot = NowPlayingSnapshot.make(track: track(artist: "", album: ""), position: 500,
                                               duration: 0, isPlaying: false, queueIndex: 0,
                                               queueCount: 1, artwork: nil)
        XCTAssertEqual(snapshot.info[MPMediaItemPropertyArtist] as? String, "Unknown Artist")
        XCTAssertNil(snapshot.info[MPMediaItemPropertyAlbumTitle])
        XCTAssertEqual(snapshot.info[MPMediaItemPropertyPlaybackDuration] as? Double, 180)
        XCTAssertEqual(snapshot.info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 180)
        XCTAssertEqual(snapshot.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(snapshot.playbackState, .paused)
    }

    func testArtworkIsPublishedWithTheCurrentTrack() throws {
        let image = try XCTUnwrap(UIImage(systemName: "music.note"))
        let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 32, height: 32)) { _ in image }
        let snapshot = NowPlayingSnapshot.make(track: track(), position: 0, duration: 180,
                                               isPlaying: true, queueIndex: 0, queueCount: 1,
                                               artwork: artwork)
        XCTAssertTrue(snapshot.info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork === artwork)
    }
}
