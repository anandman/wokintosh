import XCTest
@testable import WokintoshCore
final class PublishedBudgetTests:XCTestCase {
    func testEarlierAndMainRowsShareTheBoundedFeedBudget()throws {
        let now=Date(),target=SessionOpenTarget(primary:"https://example.com/"+String(repeating:"x",count:3800),fallback:"https://example.com/"+String(repeating:"y",count:3800))
        let rows=(0..<32).map {i in SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:"session-\(i)",provider:"codex",title:"Task",project:"Project",state:.finished,updatedAt:now,openURLs:SessionOpenURLs(macOS:target,iOS:target)),completionPending:true,completionObservedAt:now.addingTimeInterval(i%2==0 ? -1000 : -10))}
        let agents=PublishedAgents.make(rows:rows,sourceObservations:["host":now],interval:.minutes15,showFinished:false,at:now)
        let widgets=(0..<8).map {_ in PublishedWidget(id:UUID(),name:"Agents",agents:agents)}
        let data=try PublishedWidgetFeed(publisherID:UUID(),publisherName:"Display",publishedAt:now,widgets:widgets).encoded()
        XCTAssertLessThanOrEqual(data.count,PublishedWidgetFeed.maximumBytes)
        let decoded=try PublishedWidgetFeed.decode(data)
        XCTAssertEqual(decoded.widgets.count,8)
        for widget in decoded.widgets {
            let a=try XCTUnwrap(widget.agents)
            XCTAssertEqual(a.totalCount,16);XCTAssertEqual(a.earlierDoneCount,16)
            XCTAssertLessThan(a.rows.count+(a.earlierRows?.count ?? 0),32)
            XCTAssertEqual(a.rows.map(\.id),Array(agents.rows.prefix(a.rows.count)).map(\.id))
        }
    }
}
