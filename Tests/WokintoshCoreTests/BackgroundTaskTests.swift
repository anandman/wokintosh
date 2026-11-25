import XCTest
@testable import WokintoshCore

final class BackgroundTaskTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    func task(_ id:String="job",kind:String="shell",status:BackgroundTaskStatus = .running,seconds:Double=0)->BackgroundTask {
        BackgroundTask(id:id,kind:kind,label:"Example task",status:status,startedAt:now.addingTimeInterval(-10),updatedAt:now.addingTimeInterval(seconds),observedAt:now.addingTimeInterval(seconds))
    }
    func session(tasks:[BackgroundTask],foreground:AgentState = .finished)->AgentSession {
        AgentSession(id:"session",provider:"claude",title:"Example",project:"example",state:foreground,updatedAt:now,
                     background:BackgroundTaskEvidence(foregroundState:foreground,foregroundUpdatedAt:now,tasks:tasks))
    }
    func row(_ session:AgentSession)->SessionRow {SessionRow(hostID:"host",hostName:"Mac",session:session)}
    func testFiniteWorkRemainsWorkingWhileMonitorCanBecomeIdle() {
        XCTAssertEqual(session(tasks:[task()]).resolvingBackground(at:now).state,.working)
        let monitor=session(tasks:[task(kind:"monitor")]).resolvingBackground(at:now)
        XCTAssertEqual(monitor.state,.idle);XCTAssertTrue(monitor.isMonitoring);XCTAssertEqual(monitor.statusLabel,"Monitoring")
    }
    func testSingleMonitorDesignationDoesNotHideAnotherFiniteTask() {
        let source=session(tasks:[task("poller"),task("build")]);let r=row(source)
        var choices=BackgroundTaskRoleStore();choices.set(.monitor,for:source.background!.tasks[0],rowID:r.id)
        let effective=choices.applying(to:r,at:now)
        XCTAssertEqual(effective.session.state,.working)
        XCTAssertEqual(effective.session.background?.tasks[0].effectiveRole,.monitor)
        XCTAssertEqual(effective.session.background?.tasks[1].effectiveRole,.work)
    }
    func testAttentionAndForegroundWorkTakePrecedenceOverMonitor() {
        for state:AgentState in [.needsAttention,.blocked,.working] {
            let value=session(tasks:[task(kind:"monitor")],foreground:state).resolvingBackground(at:now)
            XCTAssertEqual(value.state,state);XCTAssertFalse(value.isMonitoring)
        }
    }
    func testMonitorChoiceCannotHideHelperPermissionRequest() {
        var child=task(kind:"subagent",status:.needsAttention);child.role = .monitor
        XCTAssertEqual(session(tasks:[child]).resolvingBackground(at:now).state,.needsAttention)
    }
    func testVerifiedWorkIsNotHiddenByAStaleMonitor() {
        var stale=task("poller",kind:"monitor");stale.observedAt=now.addingTimeInterval(-2000)
        XCTAssertEqual(session(tasks:[stale,task("build")]).resolvingBackground(at:now).state,.working)
    }
    func testTopLevelAttentionIsPreservedThroughOptionalBackground()throws {
        var value=session(tasks:[task(kind:"monitor")]);value.state = .needsAttention
        XCTAssertEqual(value.resolvingBackground(at:now).state,.needsAttention)
        for state in ["needsAttention","blocked"] {
            let text="{\"id\":\"session\",\"provider\":\"codex\",\"title\":\"Example\",\"project\":\"example\",\"state\":\""+state+"\",\"updatedAt\":1800000000,\"background\":{\"version\":1,\"tasks\":\"bad\"}}"
            XCTAssertEqual(try JSONDecoder().decode(AgentSession.self,from:Data(text.utf8)).state.rawValue,state)
        }
    }
    func testUnverifiedTaskBecomesUnknownRatherThanDoneOrPermanentWorking() {
        let source=session(tasks:[task()])
        XCTAssertEqual(source.resolvingBackground(at:now.addingTimeInterval(1801)).state,.unknown)
        XCTAssertEqual(session(tasks:[task(status:.unknown)]).resolvingBackground(at:now).state,.unknown)
    }
    func testMonitorVisibleBelowWorkingWithInactiveRowsHidden() {
        let work=row(session(tasks:[task()] ).resolvingBackground(at:now))
        var monitor=row(session(tasks:[task(kind:"monitor")]).resolvingBackground(at:now));monitor.session.id="monitor"
        var idle=row(session(tasks:[],foreground:.idle));idle.session.id="idle"
        let page=AgentPresentation.make(rows:[idle,monitor,work],capacity:8,showFinished:false)
        XCTAssertEqual(page.visible.map(\.session.id),["session","monitor"])
        XCTAssertEqual(page.workingCount,1);XCTAssertEqual(page.monitoringCount,1)
    }
    func testTaskIncarnationPreventsOverrideReuseAndAutomaticClearsChoice()throws {
        let original=task();let r=row(session(tasks:[original]));var choices=BackgroundTaskRoleStore()
        choices.set(.monitor,for:original,rowID:r.id)
        var reused=original;reused.startedAt=now.addingTimeInterval(1)
        XCTAssertEqual(choices.role(for:reused,rowID:r.id),.automatic)
        let data=try JSONEncoder().encode(choices);let restored=try JSONDecoder().decode(BackgroundTaskRoleStore.self,from:data)
        XCTAssertEqual(restored.role(for:original,rowID:r.id),.monitor)
        choices.set(.automatic,for:original,rowID:r.id);XCTAssertEqual(choices.role(for:original,rowID:r.id),.automatic)
    }
    func testPublishedFeedPreservesMonitoringAndStripsActivity()throws {
        let monitor=session(tasks:[task(kind:"monitor")]).resolvingBackground(at:now)
        let agents=PublishedAgents.make(rows:[row(monitor)],sourceObservations:["host":now],interval:.untilReviewed,showFinished:false,at:now)
        let feed=PublishedWidgetFeed(publisherID:UUID(),publisherName:"Mac",publishedAt:now,widgets:[PublishedWidget(id:UUID(),name:"Agents",agents:agents)])
        let decoded=try PublishedWidgetFeed.decode(feed.encoded())
        let result=try XCTUnwrap(decoded.widgets.first?.agents?.rows.first)
        XCTAssertTrue(result.session.isMonitoring);XCTAssertEqual(result.session.background?.tasks.count,1);XCTAssertNil(result.session.activity)
    }
    func testForegroundCompletionCanBeReviewedThenReturnToMonitoring() {
        var tracker=CompletionTracker();var source=session(tasks:[task(kind:"monitor")],foreground:.working)
        tracker.ingest([row(source.resolvingBackground(at:now))],at:now.addingTimeInterval(-1))
        source.background?.foregroundState = .finished;source.background?.foregroundUpdatedAt=now.addingTimeInterval(1)
        let idle=source.resolvingBackground(at:now.addingTimeInterval(2))
        tracker.ingest([row(idle)],at:now.addingTimeInterval(2))
        XCTAssertEqual(tracker.pending.count,1)
        tracker.review(row(idle).id)
        source.background?.tasks[0].observedAt=now.addingTimeInterval(30)
        tracker.ingest([row(source.resolvingBackground(at:now.addingTimeInterval(30)))],at:now.addingTimeInterval(30))
        XCTAssertTrue(tracker.pending.isEmpty)
    }
    func testRoutineMonitorLifecycleDoesNotCreateNewDoneNotice() {
        var tracker=CompletionTracker();var source=session(tasks:[task(kind:"monitor")])
        tracker.ingest([row(source.resolvingBackground(at:now))],at:now)
        source.background?.tasks[0].status = .completed;source.background?.tasks[0].updatedAt=now.addingTimeInterval(10)
        tracker.ingest([row(source.resolvingBackground(at:now.addingTimeInterval(10)))],at:now.addingTimeInterval(10))
        XCTAssertTrue(tracker.pending.isEmpty)
    }
    func testLateBackgroundEvidenceCorrectsSameTimestampFalseDone() {
        var tracker=CompletionTracker()
        let work=AgentSession(id:"session",provider:"claude",title:"Example",project:"example",state:.working,updatedAt:now.addingTimeInterval(-1))
        tracker.ingest([row(work)],at:now.addingTimeInterval(-2))
        var finished=work;finished.state = .finished;finished.updatedAt=now
        tracker.ingest([row(finished)],at:now)
        XCTAssertEqual(tracker.pending.count,1)
        let corrected=session(tasks:[task()]).resolvingBackground(at:now.addingTimeInterval(1))
        tracker.ingest([row(corrected)],at:now.addingTimeInterval(1))
        XCTAssertTrue(tracker.pending.isEmpty)
    }
    func testMalformedOptionalBackgroundCannotInventDone()throws {
        let text="""
        {"id":"session","provider":"codex","title":"Example","project":"example","state":"finished","updatedAt":1800000000,"background":{"version":1,"tasks":"bad"}}
        """
        let value=try JSONDecoder().decode(AgentSession.self,from:Data(text.utf8))
        XCTAssertEqual(value.state,.unknown);XCTAssertNil(value.background)
    }
}
