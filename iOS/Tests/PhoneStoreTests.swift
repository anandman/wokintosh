import XCTest
import WokintoshCore

private final class StoreTestCredentials:PhoneCredentialStore,@unchecked Sendable {
    var value:PhonePairing?
    var locked=false
    func load()throws->PhonePairing? {if locked {throw PhoneStorageError.keychain};return value}
    func save(_ value:PhonePairing)throws {self.value=value}
    func remove()throws {value=nil}
}
private struct StoreTestClient:PhoneFetching {
    let feed:PublishedWidgetFeed?
    func fetch(_ pairing:PhonePairing)async throws->PublishedWidgetFeed {
        guard let feed else {throw PhoneFetchError.unauthorized};return feed
    }
}
final class PhoneStoreTests:XCTestCase {
    @MainActor func testBackgroundTaskSheetBuildsQualifiedRoleCommandWithoutOpeningProvider()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let credentials=StoreTestCredentials();credentials.value=try pairing()
        let now=Date(),task=BackgroundTask(id:"runner",kind:"shell",label:"Inbox poller",status:.running,startedAt:now,updatedAt:now,observedAt:now)
        let session=AgentSession(id:"example",provider:"codex",title:"Example",project:"example",state:.working,updatedAt:now,background:BackgroundTaskEvidence(foregroundState:.finished,foregroundUpdatedAt:now,tasks:[task]))
        var agents=PublishedAgents.make(rows:[SessionRow(hostID:"host",hostName:"Mac",session:session)],sourceObservations:["host":now],interval:.untilReviewed,showFinished:false,at:now)
        agents.rows[0].backgroundControls=PublishedBackgroundControls(revision:String(repeating:"a",count:64),taskIDs:["runner"])
        let widget=PublishedWidget(id:UUID(),name:"Agents",agents:agents)
        let feed=PublishedWidgetFeed(publisherID:UUID(),publisherName:"Mac",publishedAt:now,widgets:[widget])
        let cache=PhoneSnapshotCache(directory:root);try cache.store(feed,fetchedAt:now)
        let store=PhoneStore(repository:PhoneRepository(cache:cache,credentials:credentials,client:StoreTestClient(feed:feed)),launch:{_,_ in XCTFail("Managing a task must not open the provider")})
        store.showBackgroundTasks(agents.rows[0])
        XCTAssertEqual(store.sessionPanel,.backgroundTasks)
        XCTAssertEqual(store.selectedSession?.id,agents.rows[0].id)
        let displayed=try XCTUnwrap(store.selectedSession),displayedTask=try XCTUnwrap(displayed.session.background?.tasks.first)
        let command=try XCTUnwrap(store.backgroundRoleCommand(.monitor,task:displayedTask,row:displayed))
        XCTAssertEqual(command.publisherID,feed.publisherID);XCTAssertEqual(command.widgetID,widget.id)
        XCTAssertEqual(command.taskID,"runner");XCTAssertEqual(command.taskRole,.monitor);XCTAssertTrue(command.isValid)
        var missing=displayedTask;missing.id="missing"
        XCTAssertNil(store.backgroundRoleCommand(.monitor,task:missing,row:displayed))
    }
    @MainActor func testStaleTaskPickerCannotAcquireAReplacementRunnersReceipt()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let credentials=StoreTestCredentials();credentials.value=try pairing()
        let now=Date(),task=BackgroundTask(id:"runner",kind:"shell",label:"Poller",status:.running,startedAt:now,updatedAt:now,observedAt:now)
        let session=AgentSession(id:"example",provider:"codex",title:"Example",project:"example",state:.working,updatedAt:now,background:BackgroundTaskEvidence(foregroundState:.finished,foregroundUpdatedAt:now,tasks:[task]))
        var agents=PublishedAgents.make(rows:[SessionRow(hostID:"host",hostName:"Mac",session:session)],sourceObservations:["host":now],interval:.untilReviewed,showFinished:false,at:now)
        agents.rows[0].backgroundControls=PublishedBackgroundControls(revision:String(repeating:"a",count:64),taskIDs:["runner"])
        let captured=agents.rows[0]
        let widget=PublishedWidget(id:UUID(),name:"Agents",agents:agents)
        var feed=PublishedWidgetFeed(publisherID:UUID(),publisherName:"Mac",publishedAt:now,widgets:[widget])
        let cache=PhoneSnapshotCache(directory:root);try cache.store(feed,fetchedAt:now)
        let store=PhoneStore(repository:PhoneRepository(cache:cache,credentials:credentials,client:StoreTestClient(feed:feed)))
        var replacement=task;replacement.startedAt=now.addingTimeInterval(10)
        var newSession=session;newSession.background?.tasks=[replacement]
        var newRow=PublishedAgentRow(row:SessionRow(hostID:"host",hostName:"Mac",session:newSession),observedAt:now)
        newRow.backgroundControls=PublishedBackgroundControls(revision:String(repeating:"b",count:64),taskIDs:["runner"])
        feed.widgets[0].agents?.rows=[newRow];try cache.store(feed,fetchedAt:now)
        store.showBackgroundTasks(newRow)
        XCTAssertNil(store.backgroundRoleCommand(.monitor,task:task,row:captured))
    }
    @MainActor func testLosingAuthorizationDismissesPrivateDetailAndItsActions() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let credentials=StoreTestCredentials();credentials.value=try pairing()
        let cache=PhoneSnapshotCache(directory:root),feed=PhoneFixtures.feed()
        try cache.store(feed,fetchedAt:Date())
        let store=PhoneStore(repository:PhoneRepository(cache:cache,credentials:credentials,client:StoreTestClient(feed:nil)),launch:{_,_ in XCTFail("No external action expected")})
        store.open(try XCTUnwrap(feed.widgets.first?.agents?.rows.first))
        XCTAssertNotNil(store.selectedSession)
        await store.refresh()
        XCTAssertFalse(store.snapshot.paired)
        XCTAssertNil(store.snapshot.feed)
        XCTAssertNil(store.selectedSession)
    }
    @MainActor func testAnInitiallyLockedKeychainCanRecoverByRefreshing() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let credentials=StoreTestCredentials();credentials.value=try pairing();credentials.locked=true
        let feed=PhoneFixtures.feed()
        let store=PhoneStore(repository:PhoneRepository(cache:PhoneSnapshotCache(directory:root),credentials:credentials,client:StoreTestClient(feed:feed)))
        XCTAssertFalse(store.snapshot.paired)
        credentials.locked=false
        await store.refresh()
        XCTAssertEqual(store.snapshot.feed?.publisherID,feed.publisherID)
    }
    @MainActor func testFailedSessionLinkDoesNotAutomaticallyOpenTheGeneralFallback() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let credentials=StoreTestCredentials();credentials.value=try pairing()
        var session=AgentSession(id:"fixture",provider:"codex",title:"Fixture",project:"Project",state:.working,updatedAt:Date())
        session.openURLs=SessionOpenURLs(iOS:SessionOpenTarget(primary:"codex://threads/fixture",fallback:"https://chatgpt.com/app"))
        let agents=PublishedAgents.make(rows:[SessionRow(hostID:"host",hostName:"Host",session:session)],sourceObservations:["host":Date()],interval:.untilReviewed,showFinished:false,at:Date())
        let widget=PublishedWidget(id:UUID(),name:"Agents",agents:agents)
        let feed=PublishedWidgetFeed(publisherID:UUID(),publisherName:"Publisher",publishedAt:Date(),widgets:[widget])
        let cache=PhoneSnapshotCache(directory:root);try cache.store(feed,fetchedAt:Date())
        var opened:[URL]=[]
        let store=PhoneStore(repository:PhoneRepository(cache:cache,credentials:credentials,client:StoreTestClient(feed:feed)),launch:{url,completion in opened.append(url);completion(false)})
        store.open(agents.rows[0])
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(opened.map(\.absoluteString),["codex://threads/fixture"])
    }
    @MainActor func testSuccessfulSessionTapsNeverPresentDetailsForEitherProvider() async throws {
        for (provider,url) in [("codex","codex://threads/fixture"),("claude","claude://code/session_fixture123456789")] {
            let fixture=try linkedFixture(provider:provider,url:url)
            defer {try? FileManager.default.removeItem(at:fixture.repository.cache.directory)}
            var callbacks:[PhoneStore.LaunchCompletion]=[],opened:[URL]=[]
            let store=PhoneStore(repository:fixture.repository,launch:{url,completion in opened.append(url);callbacks.append(completion)})
            store.handle(fixture.route.url)
            XCTAssertNil(store.selectedSession,"A valid widget tap must hand off without presenting a sheet")
            XCTAssertEqual(opened.map(\.absoluteString),[url])
            callbacks[0](true)
            try await Task.sleep(for:.milliseconds(20))
            XCTAssertNil(store.selectedSession)
            store.open(fixture.row)
            XCTAssertNil(store.selectedSession,"List-row taps use the same direct handoff")
        }
    }
    @MainActor func testFailedHandoffOffersDetailsAndIgnoresAnOlderTapCallback() async throws {
        let fixture=try linkedFixture(provider:"codex",url:"codex://threads/fixture")
        defer {try? FileManager.default.removeItem(at:fixture.repository.cache.directory)}
        var callbacks:[PhoneStore.LaunchCompletion]=[]
        let store=PhoneStore(repository:fixture.repository,launch:{_,completion in callbacks.append(completion)})
        store.open(fixture.route)
        XCTAssertNil(store.selectedSession)
        store.open(fixture.route)
        callbacks[0](false)
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertNil(store.selectedSession,"A superseded failure must not interrupt a newer tap")
        callbacks[1](false)
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(store.selectedSession?.id,fixture.row.id)
        XCTAssertNotNil(store.navigationMessage)
    }
    @MainActor func testAuthorizationLossCancelsPendingHandoffFailureDetails() async throws {
        let fixture=try linkedFixture(provider:"codex",url:"codex://threads/fixture",authorized:false)
        defer {try? FileManager.default.removeItem(at:fixture.repository.cache.directory)}
        var callback:PhoneStore.LaunchCompletion?
        let store=PhoneStore(repository:fixture.repository,launch:{_,completion in callback=completion})
        store.open(fixture.route)
        await store.refresh()
        callback?(false)
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertNil(store.selectedSession);XCTAssertNil(store.snapshot.feed)
    }
    @MainActor func testControlsAreUnavailableWithoutPublishedCapabilities()throws {
        let fixture=try linkedFixture(provider:"codex",url:"codex://threads/fixture")
        defer{try? FileManager.default.removeItem(at:fixture.repository.cache.directory)}
        let store=PhoneStore(repository:fixture.repository)
        XCTAssertNil(store.controlCommand(.reviewDone,rowID:fixture.row.id))
        let widgetRoute=PhoneWidgetRoute(publisherID:fixture.route.publisherID,widgetID:fixture.route.widgetID)
        store.handle(widgetRoute.url)
        XCTAssertEqual(store.earlierSelection,widgetRoute)
        store.handle(PhoneWidgetRoute(publisherID:fixture.route.publisherID,widgetID:fixture.route.widgetID,section:.agents).url)
        XCTAssertNil(store.earlierSelection);XCTAssertEqual(store.selectedWidgetID,fixture.route.widgetID)
        store.handle(PhoneWidgetRoute(publisherID:UUID(),widgetID:fixture.route.widgetID).url)
        XCTAssertNil(store.earlierSelection)
    }
    @MainActor func testCompletedActionCannotRestoreAnUnpairedMainActorView()async throws {
        let fixture=try linkedFixture(provider:"codex",url:"codex://threads/fixture")
        defer{try? FileManager.default.removeItem(at:fixture.repository.cache.directory)}
        let original=try XCTUnwrap(fixture.repository.cache.load()),gate=StoreActionGate()
        let repository=PhoneRepository(cache:fixture.repository.cache,credentials:fixture.repository.credentials,client:gate)
        let store=PhoneStore(repository:repository)
        let command=AgentControlCommand(publisherID:original.publisherID,widgetID:fixture.route.widgetID,rowID:fixture.row.id,action:.markBlocked,revision:String(repeating:"a",count:64))
        let task=Task {await store.perform(command)};await gate.waitUntilStarted()
        let result=PublishedWidgetFeed(publisherID:original.publisherID,publisherName:"After action",publishedAt:Date(),widgets:original.widgets)
        let delivery=Task.detached {await gate.finish(result)}
        // Hold the main actor while the repository commits and returns off-actor.
        waitForActionCache(repository.cache)
        XCTAssertEqual(repository.cache.load()?.publisherName,"After action")
        store.unpair()
        await delivery.value;await task.value
        XCTAssertNil(store.snapshot.feed);XCTAssertFalse(store.snapshot.paired)
        XCTAssertNil(repository.cache.load())
    }
    @MainActor func testWidgetRouteClosesNestedSettingsBeforeShowingEarlierDone()throws {
        let fixture=try linkedFixture(provider:"codex",url:"codex://threads/fixture")
        defer{try? FileManager.default.removeItem(at:fixture.repository.cache.directory)}
        let store=PhoneStore(repository:fixture.repository)
        store.settingsVisible=true;store.settingsSheet = .scan
        let route=PhoneWidgetRoute(publisherID:fixture.route.publisherID,widgetID:fixture.route.widgetID)
        store.handle(route.url)
        XCTAssertNil(store.settingsSheet);XCTAssertTrue(store.settingsVisible);XCTAssertNil(store.earlierSelection)
        store.settingsSheetDismissed()
        XCTAssertFalse(store.settingsVisible);XCTAssertNil(store.earlierSelection)
        store.settingsDismissed()
        XCTAssertEqual(store.earlierSelection,route)
    }
    @MainActor func testWidgetEarlierRouteWaitsForSessionDetailsDismissal()throws {
        let fixture=try linkedFixture(provider:"codex",url:"codex://threads/fixture")
        defer{try? FileManager.default.removeItem(at:fixture.repository.cache.directory)}
        let store=PhoneStore(repository:fixture.repository)
        store.showSessionDetails(fixture.row)
        let route=PhoneWidgetRoute(publisherID:fixture.route.publisherID,widgetID:fixture.route.widgetID)
        store.handle(route.url)
        XCTAssertNil(store.selectedSession);XCTAssertNil(store.earlierSelection)
        store.sessionDetailsDismissed()
        XCTAssertEqual(store.earlierSelection,route)
    }
    @MainActor func testRepeatedWidgetRouteStillWaitsForSettingsDismissal()throws {
        let fixture=try linkedFixture(provider:"codex",url:"codex://threads/fixture")
        defer{try? FileManager.default.removeItem(at:fixture.repository.cache.directory)}
        let store=PhoneStore(repository:fixture.repository)
        store.settingsVisible=true
        let route=PhoneWidgetRoute(publisherID:fixture.route.publisherID,widgetID:fixture.route.widgetID)
        store.handle(route.url);store.handle(route.url)
        XCTAssertNil(store.earlierSelection)
        store.settingsDismissed()
        XCTAssertEqual(store.earlierSelection,route)
    }
    private func linkedFixture(provider:String,url:String,authorized:Bool=true)throws->(repository:PhoneRepository,route:PhoneRoute,row:PublishedAgentRow) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let credentials=StoreTestCredentials();credentials.value=try pairing()
        let session=AgentSession(id:"fixture",provider:provider,title:"Fixture",project:"Project",state:.working,updatedAt:Date(),
                                 openURLs:SessionOpenURLs(iOS:SessionOpenTarget(primary:url,fallback:"https://chatgpt.com/app")))
        let agents=PublishedAgents.make(rows:[SessionRow(hostID:"host",hostName:"Host",session:session)],sourceObservations:["host":Date()],interval:.untilReviewed,showFinished:false,at:Date())
        let widget=PublishedWidget(id:UUID(),name:"Agents",agents:agents)
        let feed=PublishedWidgetFeed(publisherID:UUID(),publisherName:"Publisher",publishedAt:Date(),widgets:[widget])
        let cache=PhoneSnapshotCache(directory:root);try cache.store(feed,fetchedAt:Date())
        return (PhoneRepository(cache:cache,credentials:credentials,client:StoreTestClient(feed:authorized ? feed : nil)),
                PhoneRoute(publisherID:feed.publisherID,widgetID:widget.id,rowID:agents.rows[0].id),agents.rows[0])
    }
    private func pairing()throws->PhonePairing {
        try PhonePairing(endpoint:"https://example.ts.net:9443/wokintosh/v1/widgets",token:String(repeating:"A",count:43))
    }
}

private actor StoreActionGate:PhoneFetching {
    var response:CheckedContinuation<PublishedWidgetFeed,Error>?
    var started:CheckedContinuation<Void,Never>?
    func fetch(_ pairing:PhonePairing)async throws->PublishedWidgetFeed {throw PhoneFetchError.unavailable}
    func perform(_ command:AgentControlCommand,pairing:PhonePairing)async throws->PublishedWidgetFeed {
        try await withCheckedThrowingContinuation {response=$0;started?.resume();started=nil}
    }
    func waitUntilStarted()async {if response != nil {return};await withCheckedContinuation {started=$0}}
    func finish(_ feed:PublishedWidgetFeed) {response?.resume(returning:feed);response=nil}
}
private func waitForActionCache(_ cache:PhoneSnapshotCache) {
    let end=Date().addingTimeInterval(3)
    while cache.load()?.publisherName != "After action",Date()<end {Thread.sleep(forTimeInterval:0.001)}
}
