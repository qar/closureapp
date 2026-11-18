import AVFoundation
import XCTest

final class AudioSessionControllerTests: XCTestCase {
    @MainActor
    func testActivationUsesPlaybackCategory() throws {
        let controller = AudioSessionController()
        try controller.activate()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        try AVAudioSession.sharedInstance().setActive(false)
    }
}
