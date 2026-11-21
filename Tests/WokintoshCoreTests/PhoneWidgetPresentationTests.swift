import XCTest
@testable import WokintoshCore

final class PhoneWidgetPresentationTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1800000000)
    func agents(_ count:Int,observedAt:Date?=nil,offlineSources:Int=0)->PublishedAgents {
        let rows=(0..<count).map {index in
            SessionRow(hostID:"source",hostName:"Source",session:AgentSession(id:"\(index)",provider:"codex",title:"Title",project:"Project",state:.working,updatedAt:now.addingTimeInterval(-86400)))
        }
        return PublishedAgents.make(rows:rows,sourceObservations:["source":observedAt ?? now],interval:.untilReviewed,showFinished:true,offlineSourceCount:offlineSources,at:now)
    }
    func testCapacitiesDiscloseAllOverflowAndPreserveSourceTime() {
        let payload=agents(8,observedAt:now.addingTimeInterval(-120))
        let medium=PhoneWidgetPresentation(agents:payload,size:.medium,accessibility:false,connection:.current,at:now)
        XCTAssertEqual(medium.rows.count,2);XCTAssertEqual(medium.hiddenCount,6)
        XCTAssertEqual(medium.asOf,now.addingTimeInterval(-120));XCTAssertFalse(medium.stale)
        XCTAssertEqual(PhoneWidgetPresentation(agents:payload,size:.large,accessibility:false,connection:.current,at:now).rows.count,5)
        XCTAssertEqual(PhoneWidgetPresentation(agents:payload,size:.medium,accessibility:true,connection:.current,at:now).rows.count,1)
        XCTAssertEqual(PhoneWidgetPresentation(agents:payload,size:.large,accessibility:true,connection:.current,at:now).rows.count,3)
    }
    func testWideAndTallWidgetsShowMoreSessionsWithHonestOverflowAndFreshness() {
        let payload=agents(16,observedAt:now.addingTimeInterval(-1700))
        for size in [PhoneWidgetSize.extraLarge,.extraLargePortrait] {
            let normal=PhoneWidgetPresentation(agents:payload,size:size,accessibility:false,connection:.current,at:now)
            XCTAssertEqual(normal.rows.count,10);XCTAssertEqual(normal.hiddenCount,6)
            XCTAssertEqual(normal.rows.map(\.id),Array(payload.rows.prefix(10)).map(\.id))
            XCTAssertEqual(normal.staleTransition,now.addingTimeInterval(101))
            let accessible=PhoneWidgetPresentation(agents:payload,size:size,accessibility:true,connection:.current,at:now)
            XCTAssertEqual(accessible.rows.count,6);XCTAssertEqual(accessible.hiddenCount,10)
        }
        XCTAssertEqual(PhoneWidgetSize.extraLarge.columns,2)
        XCTAssertEqual(PhoneWidgetSize.extraLargePortrait.columns,1)
    }
    func testSpaceLimitedWidgetsKeepOrderedRowsAndDiscloseEveryOmission() {
        let payload=agents(8)
        let compact=PhoneWidgetPresentation(agents:payload,size:.medium,accessibility:false,connection:.current,at:now,maximumRows:1)
        XCTAssertEqual(compact.rows.map(\.id),Array(payload.rows.prefix(1)).map(\.id))
        XCTAssertEqual(compact.hiddenCount,7)
        let minimal=PhoneWidgetPresentation(agents:payload,size:.medium,accessibility:true,connection:.current,at:now,maximumRows:0)
        XCTAssertTrue(minimal.rows.isEmpty);XCTAssertEqual(minimal.hiddenCount,8)
        XCTAssertEqual(minimal.asOf,payload.sourceObservedAt)
        let oversized=PhoneWidgetPresentation(agents:payload,size:.medium,accessibility:false,connection:.current,at:now,maximumRows:99)
        XCTAssertEqual(oversized.rows.count,2)
    }
    func testTimelineSchedulesStalenessWithoutClaimingAnotherSuccessfulFetch() {
        let payload=agents(2,observedAt:now.addingTimeInterval(-1700))
        let view=PhoneWidgetPresentation(agents:payload,size:.medium,accessibility:false,connection:.current,at:now)
        XCTAssertEqual(view.staleTransition,now.addingTimeInterval(101))
        let old=PhoneWidgetPresentation(agents:payload,size:.medium,accessibility:false,connection:.current,at:now.addingTimeInterval(101))
        XCTAssertTrue(old.stale);XCTAssertEqual(old.asOf,view.asOf)
        XCTAssertNil(old.staleTransition)
    }
    func testTimelineStillExpiresVisibleRowsWhenAnotherSourceIsOffline() {
        let payload=agents(2,observedAt:now.addingTimeInterval(-1700),offlineSources:1)
        let view=PhoneWidgetPresentation(agents:payload,size:.medium,accessibility:false,connection:.current,at:now)
        XCTAssertTrue(view.offline)
        XCTAssertEqual(view.staleTransition,now.addingTimeInterval(101))
    }
    func testEveryVisibleRowHasAStaleEntryEvenIfAnotherRowIsAlreadyStale() {
        var payload=agents(3)
        let source=payload.rows
        payload.rows=source.enumerated().map {index,row in
            let sessionRow=SessionRow(hostID:row.hostID,hostName:row.hostName,session:row.session)
            return PublishedAgentRow(row:sessionRow,observedAt:now.addingTimeInterval([-1900,-1700,-1600][index]))
        }
        let normal=PhoneWidgetPresentation(agents:payload,size:.large,accessibility:false,connection:.current,at:now)
        XCTAssertTrue(normal.stale)
        XCTAssertEqual(normal.staleTransitions,[now.addingTimeInterval(101),now.addingTimeInterval(201)])
        let accessible=PhoneWidgetPresentation(agents:payload,size:.medium,accessibility:true,connection:.current,at:now)
        XCTAssertTrue(accessible.stale);XCTAssertTrue(accessible.staleTransitions.isEmpty)
    }
    func testAnEmptyWidgetStillReportsItsOfflineSourceImmediately() {
        let view=PhoneWidgetPresentation(agents:agents(0,offlineSources:1),size:.medium,accessibility:false,connection:.current,at:now)
        XCTAssertTrue(view.offline)
        XCTAssertEqual(view.asOf,now)
        let network=PhoneWidgetPresentation(agents:agents(2),size:.medium,accessibility:false,connection:.offline,at:now)
        XCTAssertTrue(network.offline)
    }
}
