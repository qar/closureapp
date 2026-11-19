import Foundation
import MediaPlayer
import XCTest

final class RemoteCommandDeliveryTests: XCTestCase {
    func testBackgroundRemoteCommandRunsOnMainActor() async {
        let callback = expectation(description: "remote callback returned")
        let delivered = expectation(description: "command delivered on main actor")

        DispatchQueue.global().async {
            let result = RemoteCommandDelivery.schedule {
                XCTAssertTrue(Thread.isMainThread)
                delivered.fulfill()
            }
            XCTAssertEqual(result, .success)
            callback.fulfill()
        }

        await fulfillment(of: [callback, delivered], timeout: 2)
    }
}
