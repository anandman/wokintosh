import XCTest
import WokintoshCore
@testable import Wokintosh

@MainActor final class CompletionStoreTests:XCTestCase {
    func testWidgetFiltersAndReviewAllScopeIncludeEarlierUnreadNotices() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=DashboardStore(dataDirectory:directory)
        let now=Date(timeIntervalSince1970:1_000_000)
        let sessions=[
            SessionRow(hostID:"a",hostName:"A",session:AgentSession(id:"codex",provider:"codex",title:"One",project:"",state:.finished,updatedAt:now)),
            SessionRow(hostID:"a",hostName:"A",session:AgentSession(id:"claude",provider:"claude",title:"Two",project:"",state:.finished,updatedAt:now)),
            SessionRow(hostID:"b",hostName:"B",session:AgentSession(id:"helper",provider:"codex",title:"Three",project:"",state:.finished,updatedAt:now,isHelper:true))]
        var tracker=CompletionTracker();tracker.ingest([],connectedHostIDs:["a","b"],at:now.addingTimeInterval(-1));tracker.ingest(sessions,at:now)
        store.document.completions=tracker
        var filtered=Widget(kind:.agents,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5));filtered.hostID="a";filtered.provider="codex";filtered.doneCollapseInterval = .hour1;filtered.showFinished=true
        let earlier=store.completionPresentation(for:filtered,at:now.addingTimeInterval(3600))
        XCTAssertEqual(earlier.earlier.map(\.session.id),["codex"]);XCTAssertTrue(earlier.main.isEmpty)
        var all=Widget(kind:.agents,frame:filtered.frame)
        XCTAssertEqual(store.completionPresentation(for:all,at:now.addingTimeInterval(3600)).main.count,2)
        all.showHelpers=true
        XCTAssertEqual(store.completionPresentation(for:all,at:now.addingTimeInterval(3600)).main.count,3)
        store.reviewAllCompletions(for:filtered)
        XCTAssertEqual(Set(store.document.completions.pending.map(\.session.id)),["claude","helper"])
    }
}
