import XCTest

final class CarPlayPageTests: XCTestCase {
    func testEveryItemIsReachableWithinTemplateLimit() {
        let total = 233
        let maximum = 100
        let pages = (0...2).map { CarPlayPage(total: total, requested: $0, maximumItems: maximum) }
        XCTAssertEqual(pages.flatMap { Array($0.range) }, Array(0..<total))
        for page in pages {
            let controls = (page.hasPrevious ? 1 : 0) + (page.hasNext ? 1 : 0)
            XCTAssertLessThanOrEqual(page.range.count + controls, maximum)
        }
    }

    func testPageClampsAfterLibraryShrinks() {
        let page = CarPlayPage(total: 4, requested: 9, maximumItems: 5)
        XCTAssertEqual(page.number, 1)
        XCTAssertEqual(page.range, 3..<4)
        XCTAssertTrue(page.hasPrevious)
        XCTAssertFalse(page.hasNext)
    }

    func testEmptyLibraryShowsFirstPage() {
        let page = CarPlayPage(total: 0, requested: 5, maximumItems: 100)
        XCTAssertEqual(page.number, 0)
        XCTAssertTrue(page.range.isEmpty)
    }
}
