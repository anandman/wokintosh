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

final class PhoneRepositoryTests:XCTestCase {
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
