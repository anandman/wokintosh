import XCTest
@testable import WokintoshCore

final class CompactWidgetTests: XCTestCase {
    func testScreenshotSizedSystemFitsFourReadingsWithoutEnlargingWidget() {
        let layout=SystemMetricLayout(width:480,height:82.5,textScale:1,count:4)
        XCTAssertEqual(layout.columns,2)
        XCTAssertGreaterThanOrEqual(layout.capacity,4)
        XCTAssertTrue(layout.compact)
    }
    func testScreenshotSizedAgentWidgetFitsTwelveSessionsAtReadableRowHeight() {
        let layout=AgentWidgetLayout(width:752,height:610.5,textScale:1)
        XCTAssertTrue(layout.singleLine)
        XCTAssertGreaterThanOrEqual(layout.capacity,12)
        XCTAssertGreaterThanOrEqual(layout.rowHeight,38)
        XCTAssertLessThanOrEqual(layout.headerHeight+layout.footerHeight+layout.rowHeight*Double(layout.capacity)+3,610.5)
    }
    func testMinimumAgentWidgetKeepsOverflowVisibleAtLargestTextSize() {
        let layout=AgentWidgetLayout(width:320,height:106.9,textScale:1.6)
        XCTAssertEqual(layout.capacity,0)
        XCTAssertLessThanOrEqual(layout.headerHeight+layout.footerHeight+3,106.9)
    }
    func testSystemReadingsAndOverflowStayWithinAvailableHeight() {
        for width in [230.4,480.0,880.0] {
            for height in [52.34,82.5,98.5,200.0] {
                for scale in [0.8,1.0,1.6] {
                    for count in [1,4,6,12] {
                        let layout=SystemMetricLayout(width:width,height:height,textScale:scale,count:count)
                        let visible=min(count,layout.capacity)
                        let rows=visible==0 ? 0 : (visible+layout.columns-1)/layout.columns
                        var occupied=layout.padding*2+Double(rows)*layout.rowHeight+Double(max(0,rows-1))*layout.spacing
                        if visible<count {occupied+=layout.spacing+layout.overflowHeight}
                        XCTAssertLessThanOrEqual(occupied,height,"\(width)×\(height), scale\(scale), count\(count)")
                    }
                }
            }
        }
    }
    func testLargerTextKeepsAgentRowsReadableWithHonestCapacity() {
        let layout=AgentWidgetLayout(width:752,height:610.5,textScale:1.6)
        XCTAssertFalse(layout.singleLine)
        XCTAssertGreaterThanOrEqual(layout.rowHeight,52*1.6)
        XCTAssertLessThanOrEqual(layout.headerHeight+layout.footerHeight+layout.rowHeight*Double(layout.capacity)+3,610.5)
    }
}
