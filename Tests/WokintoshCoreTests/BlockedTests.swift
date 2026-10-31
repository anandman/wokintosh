import XCTest
@testable import WokintoshCore

final class BlockedTests: XCTestCase {
    func testBlockedWireRemainsVisibleBeforeDoneAndWorkingWithoutExtraCounts() throws {
        let data=Data(#"{"schemaVersion":1,"host":{"id":"h","name":"Host","platform":"linux"},"generatedAt":"2026-10-29T22:00:00Z","sessions":[{"id":"blocked","provider":"claude","title":"Acceptance","project":"p","state":"blocked","updatedAt":"2026-09-01T22:00:00Z"}],"system":{}}"#.utf8)
        let session=try XCTUnwrap(Snapshot.decode(data).sessions.first)
        XCTAssertEqual(session.state.rawValue,"blocked")
        let blocked=SessionRow(hostID:"h",hostName:"Host",session:session)
        var done=blocked;done.session.id="done";done.session.state = .finished;done.completionPending=true
        var working=blocked;working.session.id="working";working.session.state = .working
        var attention=blocked;attention.session.id="attention";attention.session.state = .needsAttention
        let page=AgentPresentation.make(rows:[working,done,blocked,attention],capacity:4)
        XCTAssertEqual(page.visible.map(\.session.id),["attention","blocked","done","working"])
        XCTAssertEqual(page.doneCount,1);XCTAssertEqual(page.attentionCount,2);XCTAssertEqual(page.workingCount,1)
    }
    func testManualBlockedSurvivesReloadMissingRuntimeAndProviderHostCollisions() throws {
        let time=Date(timeIntervalSince1970:1000000)
        let row=SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:"same",provider:"codex",title:"Acceptance",project:"p",state:.finished,updatedAt:time))
        var document=DashboardDocument(widgets:[])
        document.blockedSessions.mark(row)
        document.blockedSessions.mark(row)
        document=try JSONDecoder().decode(DashboardDocument.self,from:JSONEncoder().encode(document))
        var otherProvider=row;otherProvider.session.provider="claude"
        var otherHost=row;otherHost.hostID="other-host"
        let rows=document.blockedSessions.applying(to:[otherProvider,otherHost],connectedHostIDs:["host"])
        XCTAssertEqual(rows.filter{$0.session.state == .blocked}.map(\.id),[row.id])
        XCTAssertEqual(rows.count,3)
        XCTAssertEqual(rows.first{$0.id == row.id}?.session.title,"Acceptance")
        XCTAssertEqual(rows.first{$0.id == row.id}?.connected,true)
        document.blockedSessions.clear(row.id)
        XCTAssertFalse(document.blockedSessions.contains(row.id))
        XCTAssertEqual(document.blockedSessions.applying(to:[],connectedHostIDs:[]),[])
    }
    func testManualBlockedSuppressesPersistedDoneButKeepsRealNeedsYouUntilClear() {
        let time=Date(timeIntervalSince1970:1000000)
        var row=SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:"same",provider:"codex",title:"Acceptance",project:"p",state:.finished,updatedAt:time),completionPending:true)
        var blocked=BlockedSessionTracker();blocked.mark(row)
        let marked=blocked.applying(to:[row],connectedHostIDs:["host"])[0]
        XCTAssertEqual(marked.session.state,.blocked);XCTAssertFalse(marked.completionPending)
        row.session.state = .needsAttention
        XCTAssertEqual(blocked.applying(to:[row],connectedHostIDs:["host"])[0].session.state,.needsAttention)
        row.session.state = .working
        XCTAssertEqual(blocked.applying(to:[row],connectedHostIDs:["host"])[0].session.state,.blocked)
        blocked.clear(row.id)
        XCTAssertEqual(blocked.applying(to:[row],connectedHostIDs:["host"])[0].session.state,.working)
    }
    func testBlockedEvidenceClearsPendingDoneEvenWithOlderLifecycleTimestamp() {
        let time=Date(timeIntervalSince1970:1000000)
        var row=SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:"same",provider:"codex",title:"Acceptance",project:"p",state:.working,updatedAt:time))
        var tracker=CompletionTracker()
        tracker.ingest([row],at:time)
        row.session.state = .finished;row.session.updatedAt=time.addingTimeInterval(1)
        tracker.ingest([row],at:time.addingTimeInterval(1));XCTAssertEqual(tracker.pending.count,1)
        row.session.state = .blocked;row.session.updatedAt=time.addingTimeInterval(-100)
        tracker.ingest([row],at:time.addingTimeInterval(2))
        XCTAssertTrue(tracker.pending.isEmpty)
    }
    func testOfflineManualBlockedStillContributesToAttentionAndOverflow() {
        var row=SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:"same",provider:"claude",title:"Acceptance",project:"p",state:.needsAttention,updatedAt:.distantPast),connected:false)
        var tracker=BlockedSessionTracker();tracker.mark(row)
        row=tracker.applying(to:[row],connectedHostIDs:[])[0]
        XCTAssertEqual(row.session.state,.blocked)
        let page=AgentPresentation.make(rows:[row],capacity:0)
        XCTAssertEqual(page.attentionCount,1);XCTAssertEqual(page.hiddenAttentionCount,1)
        XCTAssertEqual(page.overflowLabel,"+1 more · 1 needs you")
    }
    func testLegacyLayoutDefaultsToNoManualBlockedSessions() throws {
        let document=try JSONDecoder().decode(DashboardDocument.self,from:Data("{\"widgets\":[]}".utf8))
        XCTAssertTrue(document.blockedSessions.records.isEmpty)
        XCTAssertTrue(document.reportedBlockedSessions.records.isEmpty)
    }

    func testReportedBlockedSurvivesReloadOfflineAndConnectedEmptyClearsOnlyReportedCache() throws {
        let row=SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:"same",provider:"codex",title:"Acceptance",project:"p",state:.blocked,updatedAt:.distantPast))
        var document=DashboardDocument(widgets:[])
        document.blockedSessions.mark(row)
        document.reportedBlockedSessions.ingest([row],connectedHostIDs:["host"])
        document=try JSONDecoder().decode(DashboardDocument.self,from:JSONEncoder().encode(document))
        let offline=document.reportedBlockedSessions.applying(to:[],connectedHostIDs:[])
        XCTAssertEqual(offline.count,1);XCTAssertEqual(offline[0].session.state,.blocked);XCTAssertFalse(offline[0].connected)
        document.reportedBlockedSessions.ingest([],connectedHostIDs:[])
        XCTAssertEqual(document.reportedBlockedSessions.records.count,1)
        document.reportedBlockedSessions.ingest([],connectedHostIDs:["host"])
        XCTAssertTrue(document.reportedBlockedSessions.records.isEmpty)
        XCTAssertTrue(document.blockedSessions.contains(row.id))
    }
    func testReportedBlockedRetainsRealAttentionAndConnectedResumeClearsIt() {
        var row=SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:"same",provider:"claude",title:"Acceptance",project:"p",state:.blocked,updatedAt:.distantPast))
        var tracker=ReportedBlockedSessionTracker();tracker.ingest([row],connectedHostIDs:["host"])
        row.session.state = .needsAttention;row.completionPending=true
        tracker.ingest([row],connectedHostIDs:["host"])
        XCTAssertEqual(tracker.records.count,1)
        let attention=tracker.applying(to:[row],connectedHostIDs:["host"])
        XCTAssertEqual(attention.first?.session.state,.needsAttention);XCTAssertEqual(attention.first?.completionPending,false)
        row.session.state = .working
        tracker.ingest([row],connectedHostIDs:["host"])
        XCTAssertEqual(tracker.records.count,1,"Unknown goal knowledge is not a resume signal")
        XCTAssertEqual(tracker.applying(to:[row],connectedHostIDs:["host"]).first?.session.state,.blocked)
        row.session.goalBlocked=false
        tracker.ingest([row],connectedHostIDs:["host"])
        XCTAssertTrue(tracker.records.isEmpty)
        XCTAssertEqual(tracker.applying(to:[row],connectedHostIDs:["host"]).first?.session.state,.working)
    }

    func testBlockedLifecycleReceiptPreventsOldDoneReappearingAfterGoalClear() throws {
        let time=Date(timeIntervalSince1970:1000000)
        var row=SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:"same",provider:"codex",title:"Acceptance",project:"p",state:.working,updatedAt:time))
        var tracker=CompletionTracker();tracker.ingest([row],at:time)
        row.session.state = .blocked;row.session.goalBlocked=true;row.session.updatedAt=time.addingTimeInterval(1)
        tracker.ingest([row],at:time.addingTimeInterval(1))
        row.session.updatedAt=time.addingTimeInterval(2);tracker.ingest([row],at:time.addingTimeInterval(2))
        tracker=try JSONDecoder().decode(CompletionTracker.self,from:JSONEncoder().encode(tracker))
        row.session.state = .finished;row.session.goalBlocked=false
        tracker.ingest([row],at:time.addingTimeInterval(3))
        XCTAssertTrue(tracker.pending.isEmpty)
        row.session.state = .working;row.session.updatedAt=time.addingTimeInterval(4);tracker.ingest([row],at:time.addingTimeInterval(4))
        row.session.state = .finished;row.session.updatedAt=time.addingTimeInterval(5);tracker.ingest([row],at:time.addingTimeInterval(5))
        XCTAssertEqual(tracker.pending.count,1)
    }
    func testExplicitGoalClearDuringInputWaitClearsOnlyReportedCache() {
        var row=SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:"same",provider:"claude",title:"Acceptance",project:"p",state:.needsAttention,updatedAt:.distantPast,goalBlocked:true))
        var reported=ReportedBlockedSessionTracker();reported.ingest([row],connectedHostIDs:["host"])
        var manual=BlockedSessionTracker();manual.mark(row)
        XCTAssertEqual(reported.records.count,1)
        row.session.goalBlocked=false
        reported.ingest([row],connectedHostIDs:["host"])
        XCTAssertTrue(reported.records.isEmpty)
        XCTAssertEqual(reported.applying(to:[row],connectedHostIDs:["host"])[0].session.state,.needsAttention)
        XCTAssertTrue(manual.contains(row.id))
    }
    func testLegacyGoalKnowledgeRemainsUnknownAndNewFlagDecodes() throws {
        let old=Data("{\"id\":\"a\",\"provider\":\"codex\",\"title\":\"A\",\"project\":\"p\",\"state\":\"needsAttention\",\"updatedAt\":0}".utf8)
        XCTAssertNil(try JSONDecoder().decode(AgentSession.self,from:old).goalBlocked)
        var value=try JSONSerialization.jsonObject(with:old) as! [String:Any];value["goalBlocked"]=true
        XCTAssertEqual(try JSONDecoder().decode(AgentSession.self,from:JSONSerialization.data(withJSONObject:value)).goalBlocked,true)
    }

}
