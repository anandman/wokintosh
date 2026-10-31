import XCTest
@testable import WokintoshCore

final class SystemMetricTests:XCTestCase {
    func testDefaultAndCompactWidgetBudgetGaugesForAllThreeReadings() {
        let normal=SystemMetricLayout(width:870,height:102,textScale:1,count:3)
        XCTAssertEqual(normal.columns,3);XCTAssertGreaterThanOrEqual(normal.capacity,3)
        XCTAssertFalse(normal.compact)
        let compact=SystemMetricLayout(width:870,height:51,textScale:1,count:3)
        XCTAssertEqual(compact.columns,3);XCTAssertGreaterThanOrEqual(compact.capacity,3)
        XCTAssertTrue(compact.compact)
    }
    func testUsageFractionsAreRealAndInvalidReadingsStayUnavailable() {
        XCTAssertEqual(SystemMetricFraction.cpu(75),0.75)
        XCTAssertEqual(SystemMetricFraction.used(used,total:1000),0.3)
        XCTAssertEqual(SystemMetricFraction.driveUsed(free:700,total:1000),0.3)
        XCTAssertNil(SystemMetricFraction.cpu(.nan));XCTAssertNil(SystemMetricFraction.cpu(-1))
        XCTAssertNil(SystemMetricFraction.used(nil,total:1000));XCTAssertNil(SystemMetricFraction.used(2000,total:1000))
        XCTAssertNil(SystemMetricFraction.driveUsed(free:10,total:0))
        XCTAssertNil(SystemMetricFraction.driveUsed(free:2000,total:1000))
    }
    private var used:UInt64 {300}
}
