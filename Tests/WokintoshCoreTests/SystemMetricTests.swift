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
    func testStartupDriveLabelDistinguishesStorageAndKeepsVolumeDetails() {
        let root=DriveReading(id:"/",name:"System",mountPoint:"/")
        XCTAssertEqual(SystemDrivePresentation.label(for:root),"Startup disk")
        XCTAssertTrue(SystemDrivePresentation.detail(for:root).contains("/"))
        let named=DriveReading(id:"/Volumes/Archive",name:"Archive",mountPoint:"/Volumes/Archive")
        XCTAssertEqual(SystemDrivePresentation.label(for:named),"Archive")
        let unavailable=DriveReading(id:"/Volumes/Backup",name:"",mountPoint:"/Volumes/Backup")
        XCTAssertEqual(SystemDrivePresentation.label(for:unavailable),"Backup")
    }
    func testPortraitScreenshotUsesReadableStackedRowsAndAvailableHeight() {
        let layout=SystemMetricLayout(width:272,height:274.5,textScale:1,count:4,minimumColumnWidth:180)
        XCTAssertEqual(layout.columns,1)
        XCTAssertFalse(layout.compact)
        XCTAssertEqual(layout.capacity,4)
        XCTAssertGreaterThanOrEqual(layout.rowHeight,60)
        XCTAssertEqual(layout.padding*2+layout.rowHeight*4+layout.spacing*3,274.5,accuracy:0.01)
    }
    func testWideScreenshotCanUseHeightToWrapCompleteMetricHeadings() {
        let layout=SystemMetricLayout(width:544,height:114.5,textScale:1,count:4,minimumColumnWidth:180,minimumWrappedColumnWidth:118,minimumInlineWidth:240)
        XCTAssertTrue(layout.columnar)
        XCTAssertEqual(layout.columns,4)
        XCTAssertEqual(layout.labelLineLimit,2)
        XCTAssertEqual(layout.capacity,4)
        XCTAssertGreaterThanOrEqual(layout.rowHeight,88)
    }
    func testLongHeadingsReflowToTwoByTwoRatherThanTruncatingFourColumns() {
        let layout=SystemMetricLayout(width:544,height:114.5,textScale:1,count:4,minimumColumnWidth:180,minimumWrappedColumnWidth:140,minimumInlineWidth:240)
        XCTAssertEqual(layout.columns,2)
        XCTAssertTrue(layout.compact)
        XCTAssertEqual(layout.capacity,4)
        XCTAssertGreaterThan(layout.rowHeight,40)
        XCTAssertEqual(layout.padding*2+layout.rowHeight*2+layout.spacing,114.5,accuracy:0.01)
    }
    func testLargeNearlySquareWidgetBalancesRowsInsteadOfOneTallStrip() {
        let layout=SystemMetricLayout(width:880,height:600,textScale:1,count:4,minimumColumnWidth:180)
        XCTAssertEqual(layout.columns,2)
        XCTAssertFalse(layout.columnar)
        XCTAssertEqual(layout.capacity,4)
    }
    func testLongNamesCanUseCompactStackedTilesWhenInlineRowsWouldBeTooWide() {
        let layout=SystemMetricLayout(width:544,height:114.5,textScale:1,count:4,minimumColumnWidth:235,minimumWrappedColumnWidth:140,minimumInlineWidth:320,minimumCompactColumnWidth:210)
        XCTAssertEqual(layout.columns,2)
        XCTAssertTrue(layout.stackedCompact)
        XCTAssertEqual(layout.capacity,4)
        XCTAssertGreaterThanOrEqual(layout.rowHeight,49)
    }
    func testPartialSingleRowKeepsItsSmallerStackedHeightBudget() {
        let layout=SystemMetricLayout(width:544,height:100,textScale:1,count:8,minimumColumnWidth:140)
        XCTAssertEqual(layout.capacity,3)
        XCTAssertFalse(layout.columnar)
        XCTAssertGreaterThanOrEqual(layout.rowHeight,60)
        XCTAssertLessThanOrEqual(layout.padding*2+layout.rowHeight+layout.spacing+layout.overflowHeight,100)
    }
    func testDisconnectedStatusHasItsOwnSpaceOutsideReadingsAndOverflow() {
        for height in [52.34,114.5,274.5] {
            for scale in [1.0,1.6] {
                let layout=SystemMetricLayout(width:544,height:height,textScale:scale,count:4,minimumColumnWidth:180,minimumWrappedColumnWidth:118,sourceAvailable:false)
                XCTAssertEqual(layout.statusHeight,min(height,26*scale),accuracy:0.01)
                let rows=layout.capacity == 0 ? 0 : (layout.capacity-1)/layout.columns+1
                var occupied=layout.padding*2+Double(rows)*layout.rowHeight+Double(max(0,rows-1))*layout.spacing+layout.statusHeight
                if layout.capacity<4 {occupied+=layout.spacing+layout.overflowHeight}
                XCTAssertLessThanOrEqual(occupied,height+0.01)
            }
        }
    }
    private var used:UInt64 {300}
}
