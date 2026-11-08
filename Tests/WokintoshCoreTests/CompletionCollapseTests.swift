import XCTest
@testable import WokintoshCore

final class CompletionCollapseTests:XCTestCase {
    let start=Date(timeIntervalSince1970:1_000_000)
    func row(_ state:AgentState,updated:Date?=nil,observed:Date?=nil,pending:Bool=false,id:String="one") -> SessionRow {
        SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:id,provider:"codex",title:"Task",project:"",state:state,updatedAt:updated ?? start),completionPending:pending,completionObservedAt:observed)
    }
    func testCollapseBoundaryPreservesUnreadAndReleasesCapacityForWork() {
        let done=row(.finished,observed:start,pending:true)
        let work=row(.working,id:"working")
        let before=CompletionPresentation.make(rows:[done,work],interval:.minutes15,at:start.addingTimeInterval(899))
        XCTAssertEqual(before.main.count,2);XCTAssertTrue(before.earlier.isEmpty)
        let after=CompletionPresentation.make(rows:[done,work],interval:.minutes15,at:start.addingTimeInterval(900))
        XCTAssertEqual(after.earlier.map(\.id),[done.id]);XCTAssertEqual(after.main.map(\.id),[work.id])
        let page=after.page(capacity:1,showFinished:true)
        XCTAssertEqual(page.visible.map(\.id),[work.id]);XCTAssertEqual(page.doneCount,1);XCTAssertEqual(page.hiddenCount,0)
        let noCapacity=after.page(capacity:0,showFinished:false)
        XCTAssertEqual(noCapacity.doneCount,1);XCTAssertEqual(noCapacity.hiddenCount,1)
        XCTAssertEqual(after.earlier[0].completionPending,true)
        XCTAssertEqual(CompletionPresentation.make(rows:[done],interval:.untilReviewed,at:start.addingTimeInterval(864000)).main.count,1)
    }
    func testOnlyPendingFinishedRowsCollapseRegardlessOfRecentInactivePreference() {
        var blocked=row(.blocked,observed:start,pending:true,id:"blocked");blocked.session.goalBlocked=true
        let rows=[blocked,row(.needsAttention,observed:start,pending:true,id:"needs"),row(.working,observed:start,pending:true,id:"working"),row(.finished,observed:start,pending:false,id:"reviewed")]
        let presentation=CompletionPresentation.make(rows:rows,interval:.hour1,at:start.addingTimeInterval(4000))
        XCTAssertTrue(presentation.earlier.isEmpty);XCTAssertEqual(presentation.main.count,4)
    }
    func testLateRemoteCompletionAgesFromLocalObservationAndSurvivesRestart() throws {
        var tracker=CompletionTracker()
        tracker.ingest([row(.working,updated:start.addingTimeInterval(-7200))],at:start.addingTimeInterval(-7200))
        tracker.ingest([row(.finished,updated:start.addingTimeInterval(-7000))],at:start)
        XCTAssertEqual(tracker.pending.first?.observedAt,start)
        tracker=try JSONDecoder().decode(CompletionTracker.self,from:JSONEncoder().encode(tracker))
        let pending=try XCTUnwrap(tracker.pending.first?.row)
        XCTAssertTrue(CompletionPresentation.make(rows:[pending],interval:.hour1,at:start.addingTimeInterval(3599)).earlier.isEmpty)
        XCTAssertEqual(CompletionPresentation.make(rows:[pending],interval:.hour1,at:start.addingTimeInterval(3600)).earlier.count,1)
        XCTAssertEqual(tracker.pending.count,1)
    }
    func testLegacyPendingStartsIntervalOnRefreshAndMetadataDoesNotResetAge() throws {
        let record=CompletionRecord(row(.finished))
        var recordJSON=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(record)) as? [String:Any]);recordJSON.removeValue(forKey:"observedAt")
        var tracker=try JSONDecoder().decode(CompletionTracker.self,from:JSONSerialization.data(withJSONObject:["pending":[recordJSON]]))
        tracker.ingest([],at:start)
        XCTAssertEqual(tracker.pending.first?.observedAt,start)
        var corrected=row(.finished);corrected.session.title="Corrected";corrected.session.isHelper=true
        tracker.ingest([corrected],at:start.addingTimeInterval(2000))
        XCTAssertEqual(tracker.pending.first?.observedAt,start);XCTAssertEqual(tracker.pending.first?.session.title,"Corrected")
    }
    func testNewTurnResetsObservationAndReviewStillRemovesCollapsedReminder() throws {
        var tracker=CompletionTracker()
        tracker.ingest([],connectedHostIDs:["host"],at:start.addingTimeInterval(-1))
        tracker.ingest([row(.finished)],at:start)
        tracker.ingest([row(.working,updated:start.addingTimeInterval(10))],at:start.addingTimeInterval(10))
        XCTAssertTrue(tracker.pending.isEmpty)
        tracker.ingest([row(.finished,updated:start.addingTimeInterval(20))],at:start.addingTimeInterval(30))
        XCTAssertEqual(tracker.pending.first?.observedAt,start.addingTimeInterval(30))
        let pending=try XCTUnwrap(tracker.pending.first)
        tracker.review(pending.id);XCTAssertTrue(tracker.pending.isEmpty)
    }
    func testPerWidgetCollapsePreferencesRoundTripAndLegacyDefaults() throws {
        var first=Widget(kind:.agents,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5));first.doneCollapseInterval = .hours4
        let second=Widget(kind:.agents,frame:first.frame)
        let document=DashboardDocument(widgets:[first,second])
        let restored=try JSONDecoder().decode(DashboardDocument.self,from:JSONEncoder().encode(document))
        XCTAssertEqual(restored.widgets.map(\.doneCollapseInterval),[.hours4,.untilReviewed])
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(first)) as? [String:Any]);json.removeValue(forKey:"doneCollapseInterval")
        XCTAssertEqual(try JSONDecoder().decode(Widget.self,from:JSONSerialization.data(withJSONObject:json)).doneCollapseInterval,.untilReviewed)
    }
}
