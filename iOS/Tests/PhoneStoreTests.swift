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
