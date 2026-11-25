import XCTest
import WokintoshCore
@testable import Wokintosh

private final class AgentTestCredentials:PublisherCredentialStore {
    var value:String?
    func load(account:String)throws->String? {value}
    func save(_ token:String,account:String)throws {value=token}
}
@MainActor final class AgentControlTests:XCTestCase {
    let now=Date()
    func fixture(provider:String="codex")throws->(DashboardStore,URL,Widget) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let publisher=WidgetPublisher(directory:root,credentials:AgentTestCredentials(),servesNetwork:false)
        let store=DashboardStore(dataDirectory:root,publisher:publisher)
        let widget=Widget(kind:.agents,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5))
        store.document.widgets=[widget]
        var options=publisher.options;options.enabled=true;options.allowAgentControls=true;options.selectedWidgetIDs=[widget.id]
        try publisher.setOptions(options,widgets:[widget])
        let stamp=ISO8601DateFormatter().string(from:now)
        let data=Data("""
        {"schemaVersion":1,"host":{"id":"host","name":"Host","platform":"macos"},"generatedAt":"\(stamp)","sessions":[{"id":"session","provider":"\(provider)","title":"Task","project":"Project","state":"working","updatedAt":"\(stamp)"}],"system":{}}
        """.utf8)
        store.feeds["host"]=FeedStatus(name:"Host",snapshot:try Snapshot.decode(data))
        var tracker=CompletionTracker();tracker.ingest([],connectedHostIDs:["host"],at:now.addingTimeInterval(-2))
        tracker.ingest([SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:"session",provider:provider,title:"Task",project:"Project",state:.finished,updatedAt:now))],at:now)
        store.document.completions=tracker;store.publishWidgets(at:now)
        return(store,root,widget)
    }
    func feed(_ store:DashboardStore)throws->PublishedWidgetFeed {try PublishedWidgetFeed.decode(XCTUnwrap(store.publisher.publishedData))}
    func command(_ store:DashboardStore,action:AgentControlAction) throws->AgentControlCommand {
        let f=try feed(store),w=try XCTUnwrap(f.widgets.first),row=try XCTUnwrap(w.agents?.rows.first)
        return AgentControlCommand(publisherID:f.publisherID,widgetID:w.id,rowID:row.id,action:action,revision:try XCTUnwrap(row.controls?.revision))
    }
    func testReviewPersistsAndDuplicateDoesNotReviewANewerTurn()throws {
        let(s,root,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let c=try command(s,action:.reviewDone)
        _=try s.applyAgentControl(c,at:now)
        XCTAssertTrue(s.document.completions.pending.isEmpty)
        let persisted=try JSONDecoder().decode(DashboardDocument.self,from:Data(contentsOf:root.appendingPathComponent("layout.json")))
        XCTAssertTrue(persisted.completions.pending.isEmpty)
        s.document.completions.ingest([SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:"session",provider:"codex",title:"Task",project:"Project",state:.finished,updatedAt:now.addingTimeInterval(5)))],at:now.addingTimeInterval(5))
        s.publishWidgets(at:now.addingTimeInterval(5))
        _=try s.applyAgentControl(c,at:now.addingTimeInterval(6))
        XCTAssertEqual(s.document.completions.pending.count,1)
        var stale=c;stale.id=UUID()
        XCTAssertThrowsError(try s.applyAgentControl(stale,at:now.addingTimeInterval(6)))
        XCTAssertEqual(s.document.completions.pending.count,1)
    }
    func testDisabledControlsAndUnselectedWidgetCannotMutate()throws {
        let(s,root,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let c=try command(s,action:.reviewDone)
        var options=s.publisher.options;options.allowAgentControls=false
        try s.publisher.setOptions(options,widgets:s.document.widgets)
        XCTAssertThrowsError(try s.applyAgentControl(c,at:now))
        XCTAssertEqual(s.document.completions.pending.count,1)
        options.allowAgentControls=true;options.selectedWidgetIDs=[]
        try s.publisher.setOptions(options,widgets:s.document.widgets)
        XCTAssertThrowsError(try s.applyAgentControl(c,at:now))
        XCTAssertFalse(PublisherOptions().allowAgentControls)
    }
    func testManualBlockClearAndDesktopEditsInvalidateOldReceipt()throws {
        let(s,root,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let mark=try command(s,action:.markBlocked)
        _=try s.applyAgentControl(mark,at:now)
        XCTAssertEqual(s.document.blockedSessions.records.count,1)
        let clear=try command(s,action:.clearManualBlocked)
        _=try s.applyAgentControl(clear,at:now)
        XCTAssertTrue(s.document.blockedSessions.records.isEmpty)
        var replay=mark;replay.id=UUID()
        XCTAssertThrowsError(try s.applyAgentControl(replay,at:now))
        let beforeDesktop=try command(s,action:.markBlocked)
        let row=try XCTUnwrap(s.rows(for:s.document.widgets[0]).first)
        s.markBlocked(row);s.clearManualBlocked(row);s.publishWidgets(at:now)
        XCTAssertThrowsError(try s.applyAgentControl(beforeDesktop,at:now))
        XCTAssertTrue(s.document.blockedSessions.records.isEmpty)
    }
    func testAdditionalProvidersShareDoneReviewAndManualBlockedControls() throws {
        for provider in ["antigravity", "opencode"] {
            let (store, root, _) = try fixture(provider: provider)
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertEqual(try feed(store).widgets.first?.agents?.rows.first?.session.provider, provider)
            _ = try store.applyAgentControl(command(store, action: .reviewDone), at: now)
            XCTAssertTrue(store.document.completions.pending.isEmpty)
            _ = try store.applyAgentControl(command(store, action: .markBlocked), at: now)
            XCTAssertEqual(store.document.blockedSessions.records.count, 1)
            _ = try store.applyAgentControl(command(store, action: .clearManualBlocked), at: now)
            XCTAssertTrue(store.document.blockedSessions.records.isEmpty)
        }
    }
    func testEarlierDoneBulkKeepsMainDoneUnread()throws {
        let(s,root,widget)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        s.document.widgets[0].doneCollapseInterval = .minutes15
        let later=SessionRow(hostID:"host",hostName:"Host",session:AgentSession(id:"later",provider:"codex",title:"New work",project:"Project",state:.finished,updatedAt:now.addingTimeInterval(999)))
        s.document.completions.ingest([later],at:now.addingTimeInterval(999))
        let displayTime=now.addingTimeInterval(1000);s.publishWidgets(at:displayTime)
        let f=try feed(s),agents=try XCTUnwrap(f.widgets[0].agents)
        XCTAssertEqual(agents.rows.count,1);XCTAssertEqual(agents.earlierRows?.count,1)
        var command=AgentControlCommand(publisherID:f.publisherID,widgetID:widget.id,rowID:nil,action:.reviewEarlierDone,revision:try XCTUnwrap(agents.earlierControls?.revision))
        command.issuedAt=displayTime
        _=try s.applyAgentControl(command,at:displayTime)
        XCTAssertEqual(s.document.completions.pending.map(\.session.id),["later"])
    }
    func testProcessRestartAndExpiredCommandsCannotChangeState()throws {
        let(s,root,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        var c=try command(s,action:.reviewDone);c.issuedAt=now.addingTimeInterval(-61)
        XCTAssertThrowsError(try s.applyAgentControl(c,at:now))
        c.issuedAt=now;s.agentControlAuthority.epoch=UUID()
        XCTAssertThrowsError(try s.applyAgentControl(c,at:now))
        XCTAssertEqual(s.document.completions.pending.count,1)
    }
    func testRealHTTPCommandPersistsAndReturnsTheUpdatedFeed()async throws {
        let(s,root,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let c=try command(s,action:.reviewDone)
        let server=try PublisherServer(token:"fixture-token",body:try currentData(s),port:0)
        server.onCommand={command in await MainActor.run {
            do {return PublisherHTTPResult(status:200,message:"OK",body:try s.applyAgentControl(command))}
            catch {return PublisherHTTPResult(status:409,message:"Conflict")}
        }}
        let port:UInt16?=await withCheckedContinuation {continuation in server.onReady={continuation.resume(returning:$0)};server.start()}
        defer{server.stop()}
        var request=URLRequest(url:URL(string:"http://127.0.0.1:\(try XCTUnwrap(port))/wokintosh/v1/agent-actions")!)
        request.httpMethod="POST";request.httpBody=try c.encoded();request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("Bearer fixture-token",forHTTPHeaderField:"Authorization")
        let(data,response)=try await URLSession.shared.data(for:request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
        XCTAssertEqual(try PublishedWidgetFeed.decode(data).widgets.first?.agents?.doneCount,0)
        XCTAssertTrue(s.document.completions.pending.isEmpty)
    }
    private func currentData(_ store:DashboardStore)throws->Data {try XCTUnwrap(store.publisher.publishedData)}
    func testBulkReceiptCannotExpandWhenAnotherWidgetFreesBytes()throws {
        let(s,root,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let target=SessionOpenTarget(primary:"https://example.com/"+String(repeating:"x",count:3800),fallback:"https://example.com/"+String(repeating:"y",count:3800))
        var widgets=(0..<2).map {_ in Widget(kind:.agents,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5))}
        widgets[0].hostID="target";widgets[1].hostID="other";s.document.widgets=widgets
        var options=s.publisher.options;options.selectedWidgetIDs=Set(widgets.map(\.id));try s.publisher.setOptions(options,widgets:widgets)
        var tracker=CompletionTracker();tracker.ingest([],connectedHostIDs:["target","other"],at:now.addingTimeInterval(-1))
        let rows=["target","other"].flatMap {host in (0..<100).map {i in SessionRow(hostID:host,hostName:host,session:AgentSession(id:"session-\(i)",provider:"codex",title:"Task",project:"Project",state:.finished,updatedAt:now,openURLs:SessionOpenURLs(macOS:target,iOS:target)))}}
        tracker.ingest(rows,at:now);s.document.completions=tracker;s.publishWidgets(at:now)
        let f=try feed(s),old=try XCTUnwrap(f.widgets.first(where:{$0.id==widgets[0].id})?.agents)
        XCTAssertLessThan(old.rows.count,100)
        let c=AgentControlCommand(publisherID:f.publisherID,widgetID:widgets[0].id,rowID:nil,action:.reviewAllDone,revision:try XCTUnwrap(old.controls?.revision))
        options.selectedWidgetIDs=[widgets[0].id];try s.publisher.setOptions(options,widgets:widgets);s.publishWidgets(at:now)
        let expanded=try XCTUnwrap(try feed(s).widgets.first?.agents)
        XCTAssertGreaterThan(expanded.rows.count,old.rows.count)
        XCTAssertThrowsError(try s.applyAgentControl(c,at:now))
        XCTAssertEqual(s.document.completions.pending.filter{$0.hostID=="target"}.count,100)
    }
    func testPersistenceFailureKeepsNoticeUnreviewed()throws {
        let(s,root,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let c=try command(s,action:.reviewDone)
        let file=root.appendingPathComponent("layout.json")
        try? FileManager.default.removeItem(at:file)
        try FileManager.default.createDirectory(at:file,withIntermediateDirectories:true)
        XCTAssertThrowsError(try s.applyAgentControl(c,at:now))
        XCTAssertEqual(s.document.completions.pending.count,1)
    }
}
