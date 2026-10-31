import XCTest
@testable import WokintoshCore

final class CalendarWidgetLayoutTests:XCTestCase {
    func testWideCompactCalendarShowsTwoEventsWhenNextOnlyIsOff() {
        let layout=CalendarWidgetLayout(width:688,height:82.5,textScale:1,eventCount:8,nextEventOnly:false)
        XCTAssertEqual(layout.style,.agenda)
        XCTAssertEqual(layout.visibleCount,2)
        XCTAssertEqual(layout.suffix,"2/8")
    }
    func testOnlyNextRetainsOneEventDetail() {
        let layout=CalendarWidgetLayout(width:688,height:300,textScale:1,eventCount:8,nextEventOnly:true)
        XCTAssertEqual(layout.style,.detail)
        XCTAssertEqual(layout.visibleCount,1)
    }
    func testNarrowTallerCalendarUsesStackedEventRows() {
        let layout=CalendarWidgetLayout(width:300,height:180,textScale:1,eventCount:8,nextEventOnly:false)
        XCTAssertEqual(layout.style,.stackedAgenda)
        XCTAssertEqual(layout.visibleCount,2)
    }
    func testCalendarRowsRespectTextScaleAndAvailableHeight() {
        for width in [240.0,480,688] {
            for height in [59.0,82.5,150,300] {
                for scale in [0.8,1,1.6] {
                    let layout=CalendarWidgetLayout(width:width,height:height,textScale:scale,eventCount:12,nextEventOnly:false)
                    if layout.style != .detail {
                        let occupied=layout.padding*2+Double(layout.visibleCount)*layout.rowHeight+Double(max(0,layout.visibleCount-1))*layout.spacing
                        XCTAssertLessThanOrEqual(occupied,height)
                    }
                }
            }
        }
    }
}
