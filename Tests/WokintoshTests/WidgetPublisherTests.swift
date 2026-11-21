import XCTest
import WokintoshCore
@testable import Wokintosh

final class MemoryPublisherCredentials:PublisherCredentialStore {
    var values:[String:String]=[:]
    func load(account:String)throws->String? {values[account]}
    func save(_ token:String,account:String)throws {values[account]=token}
}

final class WidgetPublisherTests:XCTestCase {
    @MainActor func testFailedSelectionPersistenceCannotRepublishPreviousConsent() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let publisher=WidgetPublisher(directory:directory,credentials:MemoryPublisherCredentials(),servesNetwork:false)
        let widget=Widget(kind:.agents,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5))
        var options=publisher.options;options.enabled=true;options.selectedWidgetIDs=[widget.id]
        try publisher.setOptions(options,widgets:[widget])
        let payload=PublishedAgents.make(rows:[],sourceObservations:[:],interval:.untilReviewed,showFinished:false,at:Date())
        let published=PublishedWidget(id:widget.id,name:"Agents",agents:payload)
        try publisher.publish([published])
        let settings=directory.appendingPathComponent("publisher-settings.json")
        try FileManager.default.removeItem(at:settings)
        try FileManager.default.createDirectory(at:settings,withIntermediateDirectories:false)
        options.selectedWidgetIDs=[]
        XCTAssertThrowsError(try publisher.setOptions(options,widgets:[widget]))
        try publisher.publish([published])
        XCTAssertNil(publisher.publishedData)
        XCTAssertFalse(publisher.options.enabled)
    }
    @MainActor func testStoreImportWithCollidingIDsRevokesPublicationAndExportsNoConsent() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let credentials=MemoryPublisherCredentials()
        let publisher=WidgetPublisher(directory:directory,credentials:credentials,servesNetwork:false)
        let store=DashboardStore(dataDirectory:directory,publisher:publisher)
        let widget=try XCTUnwrap(store.document.widgets.first(where:{$0.kind == .agents}))
        var options=publisher.options;options.enabled=true;options.selectedWidgetIDs=[widget.id]
        try publisher.setOptions(options,widgets:store.document.widgets)
        store.publishWidgets()
        XCTAssertNotNil(publisher.publishedData)
        let exported=try DashboardSetup.export(document:store.document,kind:.setup).encoded()
        XCTAssertFalse(String(decoding:exported,as:UTF8.self).contains("publisher"))
        let incoming=try DashboardSetup.decode(exported)
        _=try store.applySetup(incoming)
        XCTAssertTrue(publisher.options.enabled)
        XCTAssertTrue(publisher.options.selectedWidgetIDs.isEmpty)
        XCTAssertNil(publisher.publishedData)
    }
    @MainActor func testImportRevokesSelectionsMissingFromTheOutgoingLayout() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let publisher=WidgetPublisher(directory:directory,credentials:MemoryPublisherCredentials(),servesNetwork:false)
        let store=DashboardStore(dataDirectory:directory,publisher:publisher)
        let stale=Widget(kind:.agents,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5))
        var options=publisher.options;options.enabled=true;options.selectedWidgetIDs=[stale.id]
        try publisher.setOptions(options,widgets:[stale])
        XCTAssertFalse(store.document.widgets.contains{$0.id==stale.id})
        var incoming=store.document;incoming.widgets=[stale]
        let setup=try DashboardSetup.export(document:incoming,kind:.setup)
        _=try store.applySetup(setup)
        XCTAssertTrue(publisher.options.selectedWidgetIDs.isEmpty)
    }
    @MainActor func testRetainedDoneUsesHostConnectivityAfterLeavingCurrentInventory() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let publisher=WidgetPublisher(directory:directory,credentials:MemoryPublisherCredentials(),servesNetwork:false)
        let store=DashboardStore(dataDirectory:directory,publisher:publisher)
        let now=Date()
        var session=AgentSession(id:"retained",provider:"codex",title:"Finished",project:"Project",state:.working,updatedAt:now.addingTimeInterval(-60))
        let active=SessionRow(hostID:"source",hostName:"Source",session:session)
        var tracker=CompletionTracker();tracker.ingest([active],at:now.addingTimeInterval(-60))
        session.state = .finished;session.updatedAt=now
        tracker.ingest([SessionRow(hostID:"source",hostName:"Source",session:session)],at:now)
        store.document.completions=tracker
        let json="""
        {"schemaVersion":1,"host":{"id":"source","name":"Source","platform":"macOS"},"generatedAt":"2026-11-20T20:00:00Z","sessions":[],"system":{}}
        """
        let snapshot=try Snapshot.decode(Data(json.utf8))
        store.feeds=["source":FeedStatus(name:"Source",snapshot:snapshot)]
        let widget=try XCTUnwrap(store.document.widgets.first(where:{$0.kind == .agents}))
        XCTAssertEqual(store.rows(for:widget).count,1)
        XCTAssertEqual(store.rows(for:widget).first?.connected,true)
        store.feeds["source"]?.error="Offline"
        XCTAssertEqual(store.rows(for:widget).first?.connected,false)
    }
    @MainActor func testDefaultOffAndSelectionReductionRevokesOldData() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let credentials=MemoryPublisherCredentials()
        let publisher=WidgetPublisher(directory:directory,credentials:credentials,servesNetwork:false)
        XCTAssertFalse(publisher.options.enabled);XCTAssertNil(publisher.publishedData);XCTAssertTrue(credentials.values.isEmpty)
        let widget=Widget(kind:.agents,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5))
        var options=publisher.options;options.enabled=true;options.selectedWidgetIDs=[widget.id]
        options.endpoint="https://display.example.ts.net:9443/wokintosh/v1/widgets"
        try publisher.setOptions(options,widgets:[widget])
        let payload=PublishedAgents.make(rows:[],sourceObservations:[:],interval:.untilReviewed,showFinished:false,at:Date())
        try publisher.publish([PublishedWidget(id:widget.id,name:"Agents",agents:payload)])
        XCTAssertEqual(try PublishedWidgetFeed.decode(XCTUnwrap(publisher.publishedData)).widgets.count,1)
        XCTAssertNotNil(try publisher.pairing())
        options.selectedWidgetIDs=[]
        try publisher.setOptions(options,widgets:[widget])
        XCTAssertNil(publisher.publishedData)
        let data=try Data(contentsOf:directory.appendingPathComponent("publisher-settings.json"))
        let token=try XCTUnwrap(credentials.values.values.first)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains(token))
        try publisher.publish([PublishedWidget(id:widget.id,name:"Agents",agents:payload)])
        XCTAssertEqual(try PublishedWidgetFeed.decode(XCTUnwrap(publisher.publishedData)).widgets.count,0)
    }
    @MainActor func testImportsWithMatchingWidgetIDsRequireSelectionAgainAndPreviewStopsServing() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let publisher=WidgetPublisher(directory:directory,credentials:MemoryPublisherCredentials(),servesNetwork:false)
        let widget=Widget(kind:.agents,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5))
        var options=publisher.options;options.enabled=true;options.selectedWidgetIDs=[widget.id]
        try publisher.setOptions(options,widgets:[widget])
        try publisher.removeSelections(for:[widget.id])
        XCTAssertTrue(publisher.options.enabled)
        XCTAssertTrue(publisher.options.selectedWidgetIDs.isEmpty)
        try publisher.publish([],preview:true)
        XCTAssertNil(publisher.publishedData)
        XCTAssertNil(try publisher.pairing())
        XCTAssertTrue(publisher.status.contains("Preview"))
    }
    @MainActor func testOnlySupportedWidgetsAndPrivateEndpointCanBeSelected() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let publisher=WidgetPublisher(directory:directory,credentials:MemoryPublisherCredentials(),servesNetwork:false)
        let widget=Widget(kind:.calendar,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5))
        var options=publisher.options;options.enabled=true;options.selectedWidgetIDs=[widget.id]
        try publisher.setOptions(options,widgets:[widget])
        XCTAssertTrue(publisher.options.selectedWidgetIDs.isEmpty)
        options.endpoint="https://public.example.com/v1/widgets"
        XCTAssertThrowsError(try publisher.setOptions(options,widgets:[widget]))
        options.endpoint="https://display.example.ts.net:443/wokintosh/v1/widgets"
        XCTAssertThrowsError(try publisher.setOptions(options,widgets:[widget]))
    }
}
