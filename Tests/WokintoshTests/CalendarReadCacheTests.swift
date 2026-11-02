import XCTest
import WokintoshCore
@testable import Wokintosh

final class CalendarReadCacheTests: XCTestCase {
    // A new permission generation must not reuse events fetched under an older grant.
    func testFreshCachedEventsRequireSameAuthorizationGeneration() {
        var cache = CalendarReadCache()
        let original = UUID(), regranted = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let info = CalendarInfo(events: [.init(id: "old", title: "Meeting", startDate: now,
                                             endDate: now.addingTimeInterval(3600), isAllDay: false)], authorized: true)
        cache.store(info, revision: original, at: now)
        XCTAssertEqual(cache.value(for: original, at: now.addingTimeInterval(1))?.events.map(\.id), ["old"])
        XCTAssertNil(cache.value(for: regranted, at: now.addingTimeInterval(1)))
        XCTAssertNil(cache.value(for: original, at: now.addingTimeInterval(60)))
        cache.invalidate()
        XCTAssertNil(cache.value(for: original, at: now.addingTimeInterval(1)))
    }
}
