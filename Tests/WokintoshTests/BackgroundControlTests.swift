import XCTest
@testable import WokintoshCore
@testable import Wokintosh

private final class BackgroundCredentials:PublisherCredentialStore {
    var value:String?
    func load(account:String)throws->String? {value}
    func save(_ token:String,account:String)throws {value=token}
}
@MainActor final class BackgroundControlTests:XCTestCase {
    let now=Date()
    func fixture()throws->(DashboardStore,URL,Widget,BackgroundTask) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let publisher=WidgetPublisher(directory:root,credentials:BackgroundCredentials(),servesNetwork:false)
        let store=DashboardStore(dataDirectory:root,publisher:publisher)
        let widget=Widget(kind:.agents,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5));store.document.widgets=[widget]
        var options=publisher.options;options.enabled=true;options.allowAgentControls=true;options.selectedWidgetIDs=[widget.id]
        try publisher.setOptions(options,widgets:[widget])
        let task=BackgroundTask(id:"poller",kind:"shell",label:"Inbox poller",status:.running,startedAt:now.addingTimeInterval(-10),updatedAt:now,observedAt:now)
        let session=AgentSession(id:"session",provider:"codex",title:"Example",project:"example",state:.working,updatedAt:now,background:BackgroundTaskEvidence(foregroundState:.finished,foregroundUpdatedAt:now,tasks:[task]))
        let snap=Snapshot(schemaVersion:1,host:HostInfo(id:"host",name:"Mac",platform:"macos"),generatedAt:now,sessions:[session],system:SystemReading())
        store.feeds["host"]=FeedStatus(name:"Mac",snapshot:snap);store.publishWidgets(at:now)
        return(store,root,widget,task)
    }
    func command(_ store:DashboardStore,role:BackgroundTaskRole)throws->AgentControlCommand {
        let feed=try PublishedWidgetFeed.decode(XCTUnwrap(store.publisher.publishedData)),widget=try XCTUnwrap(feed.widgets.first),row=try XCTUnwrap(widget.agents?.rows.first)
        return AgentControlCommand(publisherID:feed.publisherID,widgetID:widget.id,rowID:row.id,action:.setBackgroundTaskRole,revision:try XCTUnwrap(row.backgroundControls?.revision),taskID:"poller",taskRole:role)
    }
    func testDesktopRolePersistsOutsideLayoutAndSetupExports()throws {
        let(store,root,widget,task)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let row=try XCTUnwrap(store.rows(for:widget).first)
        try store.setBackgroundTaskRole(.monitor,taskID:task.id,row:row)
        XCTAssertTrue(try XCTUnwrap(store.rows(for:widget).first).session.isMonitoring)
        let loaded=DashboardStore(dataDirectory:root,publisher:store.publisher)
        loaded.feeds=store.feeds;loaded.document.widgets=[widget]
        XCTAssertTrue(try XCTUnwrap(loaded.rows(for:widget).first).session.isMonitoring)
        let data=try DashboardSetup.export(document:store.document,kind:.setup).encoded()
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("poller"))
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(store.document),as:UTF8.self).contains("backgroundTaskRoles"))
    }
    func testMobileRoleReturnsSharedStateAndRejectsStaleReceipt()throws {
        let(store,root,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let first=try command(store,role:.monitor)
        let feed=try PublishedWidgetFeed.decode(store.applyAgentControl(first,at:now))
        XCTAssertTrue(try XCTUnwrap(feed.widgets.first?.agents?.rows.first).session.isMonitoring)
        XCTAssertNotNil(feed.widgets.first?.agents?.rows.first?.backgroundControls)
        _=try store.applyAgentControl(first,at:now)
        var stale=first;stale.id=UUID();XCTAssertThrowsError(try store.applyAgentControl(stale,at:now))
        let reset=try command(store,role:.automatic)
        let updated=try PublishedWidgetFeed.decode(store.applyAgentControl(reset,at:now))
        XCTAssertEqual(updated.widgets.first?.agents?.rows.first?.session.state,.working)
    }
    func testReusedTaskAndDisabledControlsCannotChangeRole()throws {
        let(store,root,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let old=try command(store,role:.monitor)
        store.feeds["host"]!.snapshot!.sessions[0].background!.tasks[0].startedAt=now.addingTimeInterval(1)
        XCTAssertThrowsError(try store.applyAgentControl(old,at:now))
        var options=store.publisher.options;options.allowAgentControls=false
        try store.publisher.setOptions(options,widgets:store.document.widgets)
        XCTAssertThrowsError(try store.applyAgentControl(old,at:now))
    }
    func testFailedRolePersistenceLeavesStateAndReceiptUnchanged()throws {
        let(store,root,widget,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let command=try command(store,role:.monitor)
        let file=root.appendingPathComponent("background-task-roles.json")
        try FileManager.default.createDirectory(at:file,withIntermediateDirectories:true)
        XCTAssertThrowsError(try store.applyAgentControl(command,at:now))
        XCTAssertEqual(store.rows(for:widget).first?.session.state,.working)
    }
    func testRetainedDoneNoticeDoesNotAuthorizeAnAbsentRunner()throws {
        let(store,root,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let command=try command(store,role:.monitor)
        var old=try XCTUnwrap(store.feeds["host"]?.snapshot?.sessions.first);old.state = .finished
        var tracker=CompletionTracker();tracker.ingest([],connectedHostIDs:["host"],at:now.addingTimeInterval(-2))
        tracker.ingest([SessionRow(hostID:"host",hostName:"Mac",session:old)],at:now)
        store.document.completions=tracker;store.feeds["host"]!.snapshot!.sessions=[]
        store.publishWidgets(at:now)
        let orphan=try XCTUnwrap(store.rows(for:store.document.widgets[0]).first)
        let feed=try PublishedWidgetFeed.decode(XCTUnwrap(store.publisher.publishedData))
        XCTAssertNil(feed.widgets.first?.agents?.rows.first?.backgroundControls)
        XCTAssertThrowsError(try store.applyAgentControl(command,at:now))
        XCTAssertThrowsError(try store.setBackgroundTaskRole(.monitor,taskID:"poller",row:orphan))
    }
    func testLegacyAllowedActionsDoNotContainNewEnumValue()throws {
        let(store,root,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let feed=try PublishedWidgetFeed.decode(XCTUnwrap(store.publisher.publishedData))
        let row=try XCTUnwrap(feed.widgets.first?.agents?.rows.first)
        XCTAssertNotNil(row.backgroundControls)
        XCTAssertFalse(row.controls?.allowed.contains(.setBackgroundTaskRole) == true)
        var invalid=try command(store,role:.monitor);invalid.taskID="not-listed"
        XCTAssertThrowsError(try store.applyAgentControl(invalid,at:now))
    }
}
