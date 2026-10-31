import XCTest
@testable import WokintoshCore

final class UsabilityTests: XCTestCase {
    func testDragUsesStableOriginAndOptionalPixelGrid() {
        let start=WidgetFrame(x:0.1,y:0.1,width:0.3,height:0.3)
        let free=WidgetInteraction.moving(start,dx:37,dy:19,snap:false)
        XCTAssertEqual(free.x,0.1+37/1280,accuracy:0.000001)
        XCTAssertEqual(free.y,0.1+19/682,accuracy:0.000001)
        let snapped=WidgetInteraction.moving(start,dx:37,dy:19,snap:true)
        XCTAssertEqual(snapped.x*1280,160,accuracy:0.000001)
        XCTAssertEqual(snapped.y*682,80,accuracy:0.000001)
        XCTAssertEqual(snapped,WidgetInteraction.moving(start,dx:37,dy:19,snap:true))
    }
    func testResizeStaysAnchoredAtCanvasEdgesAndMinimumSize() {
        let start=WidgetFrame(x:0.6,y:0.65,width:0.25,height:0.2)
        let large=WidgetInteraction.resizing(start,dx:1000,dy:1000,kind:.agents,snap:true)
        XCTAssertEqual(large.width,0.4,accuracy:0.000001)
        XCTAssertEqual((large.y+large.height)*682,672,accuracy:0.000001)
        XCTAssertEqual(large.x,start.x);XCTAssertEqual(large.y,start.y)
        XCTAssertLessThanOrEqual(large.x+large.width,1)
        XCTAssertLessThanOrEqual(large.y+large.height,1)
        let small=WidgetInteraction.resizing(start,dx:-1000,dy:-1000,kind:.agents,snap:true)
        XCTAssertEqual(small.width,0.25)
        XCTAssertGreaterThanOrEqual(small.height,0.2)
        XCTAssertEqual((small.y+small.height)*682,592,accuracy:0.000001)
    }
    func testCompletionSurvivesReloadUntilReviewedThenReappearsForNewTurn() throws {
        let now=Date(timeIntervalSince1970:1000000)
        var tracker=baselined(at:now)
        let done=row(.finished,at:now)
        tracker.ingest([row(.working,at:now.addingTimeInterval(-60))],at:now)
        tracker.ingest([done],at:now)
        XCTAssertEqual(tracker.pending.count,1)
        tracker=try JSONDecoder().decode(CompletionTracker.self,from:JSONEncoder().encode(tracker))
        tracker.ingest([],at:now.addingTimeInterval(3*86400))
        XCTAssertEqual(tracker.pending.first?.row.completionPending,true)
        tracker.review(done.id)
        tracker.ingest([done],at:now)
        XCTAssertTrue(tracker.pending.isEmpty)
        tracker.ingest([row(.working,at:now.addingTimeInterval(100))],at:now.addingTimeInterval(100))
        tracker.ingest([row(.finished,at:now.addingTimeInterval(200))],at:now.addingTimeInterval(200))
        XCTAssertEqual(tracker.pending.count,1)
    }
    func testOldHistoryDoesNotFloodDoneAndDisconnectedStateCannotInventCompletion() {
        let now=Date(timeIntervalSince1970:1000000)
        var tracker=baselined(at:now)
        tracker.ingest([row(.finished,at:now.addingTimeInterval(-2*86400))],at:now)
        var offline=row(.finished,at:now);offline.connected=false
        tracker.ingest([offline],at:now)
        XCTAssertTrue(tracker.pending.isEmpty)
        tracker.ingest([row(.finished,at:now)],at:now)
        XCTAssertEqual(tracker.pending.count,1)
        tracker.ingest([row(.working,at:now.addingTimeInterval(1))],at:now)
        XCTAssertTrue(tracker.pending.isEmpty)
    }
    func testNewerConnectedUnknownOrIdleSupersedesPersistedCompletion() throws {
        let now=Date(timeIntervalSince1970:1000000)
        for state in [AgentState.unknown,.idle] {
            var tracker=baselined(at:now)
            let done=row(.finished,at:now)
            let other=row(.finished,at:now,id:"other")
            tracker.ingest([done,other],at:now)
            tracker=try JSONDecoder().decode(CompletionTracker.self,from:JSONEncoder().encode(tracker))
            tracker.ingest([row(state,at:now.addingTimeInterval(1))],at:now.addingTimeInterval(1))
            XCTAssertEqual(tracker.pending.map(\.id),[other.id],"Newer \(state) must supersede only its own completion")
        }
    }
    func testEqualOrOlderConnectedActivityPreservesPendingCompletion() {
        let now=Date(timeIntervalSince1970:1000000)
        let done=row(.finished,at:now)
        for state in [AgentState.working,.needsAttention,.unknown,.idle] {
            for offset in [-1.0,0.0] {
                var tracker=baselined(at:now)
                tracker.ingest([done],at:now)
                tracker.ingest([row(state,at:now.addingTimeInterval(offset))],at:now)
                XCTAssertEqual(tracker.pending,[CompletionRecord(done)],"\(state) at offset \(offset) is not newer activity")
            }
        }
    }
    func testDisconnectedActivityPreservesPendingCompletion() {
        let now=Date(timeIntervalSince1970:1000000)
        let done=row(.finished,at:now)
        for state in [AgentState.working,.needsAttention,.unknown,.idle] {
            var tracker=baselined(at:now)
            tracker.ingest([done],at:now)
            var offline=row(state,at:now.addingTimeInterval(1))
            offline.connected=false
            tracker.ingest([offline],at:now.addingTimeInterval(1))
            XCTAssertEqual(tracker.pending,[CompletionRecord(done)],"Disconnected \(state) cannot supersede a completion")
        }
    }
    func testSupersededCompletionCannotReplayAfterReloadButNewCompletionAppears() throws {
        let now=Date(timeIntervalSince1970:1000000)
        for state in [AgentState.unknown,.idle] {
            var tracker=baselined(at:now)
            let oldDone=row(.finished,at:now)
            tracker.ingest([oldDone],at:now)
            tracker.ingest([row(state,at:now.addingTimeInterval(1))],at:now.addingTimeInterval(1))
            tracker=try JSONDecoder().decode(CompletionTracker.self,from:JSONEncoder().encode(tracker))
            tracker.ingest([oldDone],at:now.addingTimeInterval(2))
            XCTAssertTrue(tracker.pending.isEmpty,"Superseded Done must not return from stale finished evidence after \(state)")
            let newDone=row(.finished,at:now.addingTimeInterval(3))
            tracker.ingest([newDone,newDone],at:now.addingTimeInterval(3))
            XCTAssertEqual(tracker.pending,[CompletionRecord(newDone)])
        }
    }
    func testUnreviewedCompletionVisibleWithoutFinishedHistoryToggle() {
        var done=row(.finished,at:Date());done.completionPending=true
        let needs=row(.needsAttention,at:Date(),id:"attention")
        let working=row(.working,at:Date(),id:"working")
        let page=AgentPresentation.make(rows:[working,done,needs],capacity:3)
        XCTAssertEqual(page.visible.map(\.session.state),[.needsAttention,.finished,.working])
    }
    func testLegacyLayoutKeepsWidgetsAndDefaultsNewOptions() throws {
        let id=UUID().uuidString
        let data=Data("{\"widgets\":[{\"id\":\"\(id)\",\"kind\":\"system\",\"frame\":{\"x\":0.1,\"y\":0.1,\"width\":0.5,\"height\":0.3},\"showFinished\":false,\"showHelpers\":false}]}".utf8)
        let layout=try JSONDecoder().decode(DashboardDocument.self,from:data)
        XCTAssertEqual(layout.widgets.count,1);XCTAssertTrue(layout.snapToGrid);XCTAssertTrue(layout.nativeFullscreen)
        XCTAssertTrue(layout.widgets[0].systemOptions.showCPU);XCTAssertNil(layout.widgets[0].systemOptions.driveIDs)
        XCTAssertTrue(layout.completions.pending.isEmpty)
    }
    func testDriveWireAndLegacySystemReadingsBothDecode() throws {
        let old=try JSONDecoder().decode(SystemReading.self,from:Data("{\"cpuPercent\":12,\"diskFreeBytes\":100}".utf8))
        XCTAssertNil(old.drives);XCTAssertEqual(old.diskFreeBytes,100)
        let new=try JSONDecoder().decode(SystemReading.self,from:Data("{\"drives\":[{\"id\":\"/Volumes/Archive\",\"name\":\"Archive\",\"mountPoint\":\"/Volumes/Archive\",\"freeBytes\":700,\"totalBytes\":1000}]}".utf8))
        XCTAssertEqual(new.drives?.first?.id,"/Volumes/Archive");XCTAssertEqual(new.drives?.first?.freeBytes,700)
    }
    private func baselined(at now:Date) -> CompletionTracker {
        var tracker=CompletionTracker()
        tracker.ingest([row(.idle,at:now.addingTimeInterval(-60),id:"baseline")],at:now.addingTimeInterval(-60))
        return tracker
    }
    private func row(_ state:AgentState,at date:Date,id:String="same") -> SessionRow {
        SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:id,provider:"codex",title:"Task",project:"project",state:state,updatedAt:date))
    }
}
