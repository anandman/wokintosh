import XCTest
@testable import WokintoshCore

final class CompletionBaselineTests: XCTestCase {
    let now=Date(timeIntervalSince1970:1_000_000)
    func testFirstInventoryDoesNotImportFinishedHistory() throws {
        var tracker=CompletionTracker()
        let old=row(.finished,at:now.addingTimeInterval(-60))
        tracker.ingest([old],at:now)
        XCTAssertTrue(tracker.pending.isEmpty)
        tracker=try JSONDecoder().decode(CompletionTracker.self,from:JSONEncoder().encode(tracker))
        tracker.ingest([old],at:now.addingTimeInterval(100))
        XCTAssertTrue(tracker.pending.isEmpty)
    }
    func testActiveTurnAndNewlyDiscoveredCompletionAfterBaselineAreNotLost() {
        var tracker=CompletionTracker()
        tracker.ingest([row(.working,at:now)],at:now)
        tracker.ingest([row(.finished,at:now.addingTimeInterval(1)),row(.finished,at:now.addingTimeInterval(2),id:"new")],at:now.addingTimeInterval(3))
        XCTAssertEqual(Set(tracker.pending.map(\.session.id)),Set(["one","new"]))
    }
    func testEachNewHostGetsIndependentBaselineAndOfflineCannotEstablishIt() {
        var tracker=CompletionTracker()
        tracker.ingest([row(.working,at:now)],at:now)
        var offline=row(.finished,at:now,host:"remote");offline.connected=false
        tracker.ingest([offline],at:now)
        tracker.ingest([row(.finished,at:now,host:"remote")],at:now.addingTimeInterval(100))
        XCTAssertTrue(tracker.pending.isEmpty)
        tracker.ingest([row(.finished,at:now.addingTimeInterval(101),host:"remote")],at:now.addingTimeInterval(102))
        XCTAssertEqual(tracker.pending.first?.hostID,"remote")
    }
    func testLegacyPendingSurvivesMigrationWithoutImportingAdditionalHistory() throws {
        let done=row(.finished,at:now.addingTimeInterval(-60))
        let data=try JSONSerialization.data(withJSONObject:["pending":[try JSONSerialization.jsonObject(with:JSONEncoder().encode(CompletionRecord(done)))],"reviewed":[:],"active":[:]])
        var tracker=try JSONDecoder().decode(CompletionTracker.self,from:data)
        tracker.ingest([done,row(.finished,at:now.addingTimeInterval(-30),id:"old")],at:now)
        XCTAssertEqual(tracker.pending.map(\.session.id),["one"])
    }
    func testOldFinishedEvidenceCannotOverrideNewerActiveTurn() {
        var tracker=CompletionTracker()
        tracker.ingest([row(.working,at:now)],at:now)
        tracker.ingest([row(.finished,at:now.addingTimeInterval(-1))],at:now.addingTimeInterval(1))
        XCTAssertTrue(tracker.pending.isEmpty)
    }
    private func row(_ state:AgentState,at date:Date,id:String="one",host:String="host") -> SessionRow {
        SessionRow(hostID:host,hostName:host,session:AgentSession(id:id,provider:"codex",title:"Task",project:"project",state:state,updatedAt:date))
    }
}

extension CompletionBaselineTests {
    func testConnectedEmptyHostCanObserveFirstCompletedSessionLater() {
        var tracker=CompletionTracker()
        tracker.ingest([],connectedHostIDs:["empty"],at:now)
        tracker.ingest([row(.finished,at:now.addingTimeInterval(1),host:"empty")],at:now.addingTimeInterval(2))
        XCTAssertEqual(tracker.pending.count,1)
    }
    func testCorrectedHelperMetadataUpdatesPersistedDoneEvenAtOlderTimestamp() {
        var tracker=CompletionTracker()
        tracker.ingest([],connectedHostIDs:["host"],at:now.addingTimeInterval(-120))
        let done=row(.finished,at:now)
        tracker.ingest([done],at:now)
        var corrected=row(.finished,at:now.addingTimeInterval(-60))
        corrected.session.isHelper=true;corrected.session.parentId="parent"
        tracker.ingest([corrected],at:now)
        XCTAssertEqual(tracker.pending.first?.session.isHelper,true)
        XCTAssertEqual(tracker.pending.first?.session.parentId,"parent")
        XCTAssertEqual(tracker.pending.first?.session.updatedAt,done.session.updatedAt)
    }
    func testLegacyAgentSessionDecodesAndInfersKnownParentHelper() throws {
        let original=row(.working,at:now).session
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as? [String:Any])
        json.removeValue(forKey:"isHelper")
        let old=try JSONDecoder().decode(AgentSession.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertFalse(old.isHelper)
        json["parentId"]="parent"
        let child=try JSONDecoder().decode(AgentSession.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertTrue(child.isHelper)
    }
}
