import XCTest
import WokintoshCore

private final class MemoryPhoneCredentials:PhoneCredentialStore,@unchecked Sendable {
    var value:PhonePairing?
    func load()throws->PhonePairing? {value}
    func save(_ value:PhonePairing)throws {self.value=value}
    func remove()throws {value=nil}
}

private struct RejectingPhoneClient:PhoneFetching {
    let error:PhoneFetchError
    func fetch(_ pairing:PhonePairing)async throws->PublishedWidgetFeed {throw error}
}

private struct ImmediatePhoneClient:PhoneFetching {
    let feed:PublishedWidgetFeed
    func fetch(_ pairing:PhonePairing)async throws->PublishedWidgetFeed {feed}
}
private actor SuspendedPhoneClient:PhoneFetching {
    private var response:CheckedContinuation<PublishedWidgetFeed,Error>?
    private var started:CheckedContinuation<Void,Never>?
    func fetch(_ pairing:PhonePairing)async throws->PublishedWidgetFeed {
        try await withCheckedThrowingContinuation {continuation in response=continuation;started?.resume();started=nil}
    }
    func waitUntilStarted()async {
        if response != nil {return}
        await withCheckedContinuation {started=$0}
    }
    func finish(_ result:Result<PublishedWidgetFeed,Error>) {response?.resume(with:result);response=nil}
}

final class PhoneRepositoryTests:XCTestCase {
    func testOldRefreshCannotModifyANewPairingAcrossRepositoryInstances() async throws {
        for outcome in 0..<6 {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            let cache=PhoneSnapshotCache(directory:root),credentials=MemoryPhoneCredentials(),delayed=SuspendedPhoneClient()
            let old=PhoneRepository(cache:cache,credentials:credentials,client:delayed)
            try old.pair(pairing())
            let request=Task {try await old.refresh()}
            await delayed.waitUntilStarted()
            let differentPair=try PhonePairing(endpoint:"https://other.example.ts.net:9443/wokintosh/v1/widgets",token:String(repeating:"B",count:43))
            let newerPair=try outcome<3 ? differentPair : pairing()
            let newerFeed=PublishedWidgetFeed(publisherID:UUID(),publisherName:"New publisher",publishedAt:Date(),widgets:[])
            let current=PhoneRepository(cache:cache,credentials:credentials,client:ImmediatePhoneClient(feed:newerFeed))
            try current.pair(newerPair)
            _=try await current.refresh()
            if outcome%3==0 {await delayed.finish(.failure(PhoneFetchError.unauthorized))}
            else if outcome%3==1 {await delayed.finish(.failure(PhoneFetchError.unavailable))}
            else {await delayed.finish(.success(PublishedWidgetFeed(publisherID:UUID(),publisherName:"Old publisher",publishedAt:Date(),widgets:[])))}
            let returned=try await request.value
            XCTAssertEqual(credentials.value,newerPair)
            XCTAssertEqual(cache.load()?.publisherID,newerFeed.publisherID)
            XCTAssertEqual(returned.feed?.publisherID,newerFeed.publisherID)
            XCTAssertEqual(returned.state,.current)
        }
    }
    func pairing()throws->PhonePairing {try PhonePairing(endpoint:"https://display.example.ts.net:9443/wokintosh/v1/widgets",token:String(repeating:"A",count:43))}
    func testUnpairedRepositoryNeverReturnsAStalePrivateFeed() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let cache=PhoneSnapshotCache(directory:root)
        try cache.store(PublishedWidgetFeed(publisherID:UUID(),publisherName:"Private",publishedAt:Date(),widgets:[]),fetchedAt:Date())
        let repository=PhoneRepository(cache:cache,credentials:MemoryPhoneCredentials(),client:RejectingPhoneClient(error:.unavailable))
        XCTAssertNil(try repository.snapshot().feed)
        XCTAssertNil(cache.load())
    }
    func testUnauthorizedFetchRemovesCredentialAndPrivateContent() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let cache=PhoneSnapshotCache(directory:root),credentials=MemoryPhoneCredentials()
        credentials.value=try pairing()
        try cache.store(PublishedWidgetFeed(publisherID:UUID(),publisherName:"Private",publishedAt:Date(),widgets:[]),fetchedAt:Date())
        let repository=PhoneRepository(cache:cache,credentials:credentials,client:RejectingPhoneClient(error:.unauthorized))
        let snapshot=try await repository.refresh()
        XCTAssertEqual(snapshot.state,.authorizationRequired)
        XCTAssertNil(snapshot.feed);XCTAssertNil(credentials.value);XCTAssertNil(cache.load())
    }
    func testTemporaryFailureKeepsLastSnapshotAndUnpairRemovesIt() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let cache=PhoneSnapshotCache(directory:root),credentials=MemoryPhoneCredentials()
        credentials.value=try pairing()
        let date=Date(timeIntervalSince1970:1800000000),id=UUID()
        try cache.store(PublishedWidgetFeed(publisherID:id,publisherName:"Display",publishedAt:date,widgets:[]),fetchedAt:date)
        let repository=PhoneRepository(cache:cache,credentials:credentials,client:RejectingPhoneClient(error:.unavailable))
        let snapshot=try await repository.refresh()
        XCTAssertEqual(snapshot.state,.offline)
        XCTAssertEqual(snapshot.feed?.publisherID,id)
        XCTAssertEqual(snapshot.lastFetchedAt,date)
        try repository.unpair()
        XCTAssertNil(try repository.snapshot().feed)
        XCTAssertNil(credentials.value)
    }
}
