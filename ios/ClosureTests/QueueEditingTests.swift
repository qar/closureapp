import XCTest

final class QueueEditingTests: XCTestCase {
    let queue = ["a", "b", "c", "d", "e"]

    func testRemovingKeepsTheCurrentTrack() throws {
        let edited = try XCTUnwrap(QueueEditing.removing([0, 2, 4], from: queue, current: 2))
        XCTAssertEqual(edited.queue, ["b", "c", "d"], "the current track c stays")
        XCTAssertEqual(edited.current, 1)
        XCTAssertNil(QueueEditing.removing([2], from: queue, current: 2), "removing only the current track does nothing")
    }

    func testMovingFollowsTheCurrentTrack() {
        // Move e to the front; c (current) shifts right.
        var edited = QueueEditing.moving([4], to: 0, in: queue, current: 2)
        XCTAssertEqual(edited.queue, ["e", "a", "b", "c", "d"])
        XCTAssertEqual(edited.current, 3)
        // Move the current track itself to the end.
        edited = QueueEditing.moving([2], to: 5, in: queue, current: 2)
        XCTAssertEqual(edited.queue, ["a", "b", "d", "e", "c"])
        XCTAssertEqual(edited.current, 4)
        // Move a later track before the current one's successor: current unchanged.
        edited = QueueEditing.moving([4], to: 3, in: queue, current: 2)
        XCTAssertEqual(edited.queue, ["a", "b", "c", "e", "d"])
        XCTAssertEqual(edited.current, 2)
    }
}
