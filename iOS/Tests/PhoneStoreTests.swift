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
    private func pairing()throws->PhonePairing {
        try PhonePairing(endpoint:"https://example.ts.net:9443/wokintosh/v1/widgets",token:String(repeating:"A",count:43))
    }
}
