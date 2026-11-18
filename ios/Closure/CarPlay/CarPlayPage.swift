import Foundation

/// Reserves two CarPlay list rows for page navigation, so no item is hidden by
/// the system's maximum item count.
struct CarPlayPage {
    let number: Int
    let range: Range<Int>
    let hasPrevious: Bool
    let hasNext: Bool

    init(total: Int, requested: Int, maximumItems: Int) {
        let count = max(0, total)
        let pageSize = max(1, maximumItems - 2)
        let lastPage = count == 0 ? 0 : (count - 1) / pageSize
        number = min(max(0, requested), lastPage)
        let start = number * pageSize
        range = start..<min(start + pageSize, count)
        hasPrevious = number > 0
        hasNext = range.upperBound < count
    }
}
