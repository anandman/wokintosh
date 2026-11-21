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
    func testTimelineSchedulesStalenessWithoutClaimingAnotherSuccessfulFetch() {
        let payload=agents(2,observedAt:now.addingTimeInterval(-1700))
        let view=PhoneWidgetPresentation(agents:payload,size:.medium,accessibility:false,connection:.current,at:now)
        XCTAssertEqual(view.staleTransition,now.addingTimeInterval(101))
        let old=PhoneWidgetPresentation(agents:payload,size:.medium,accessibility:false,connection:.current,at:now.addingTimeInterval(101))
        XCTAssertTrue(old.stale);XCTAssertEqual(old.asOf,view.asOf)
        XCTAssertNil(old.staleTransition)
    }
    func testAnEmptyWidgetStillReportsItsOfflineSourceImmediately() {
        let view=PhoneWidgetPresentation(agents:agents(0,offlineSources:1),size:.medium,accessibility:false,connection:.current,at:now)
        XCTAssertTrue(view.offline)
        XCTAssertEqual(view.asOf,now)
        let network=PhoneWidgetPresentation(agents:agents(2),size:.medium,accessibility:false,connection:.offline,at:now)
        XCTAssertTrue(network.offline)
    }
}
