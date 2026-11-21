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
    func perform(_ command:AgentControlCommand,pairing:PhonePairing)async throws->PublishedWidgetFeed {try await fetch(pairing)}
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
    func testLatestRequestWinsWhenSamePairingResponsesCompleteInReverseOrder() async throws {
        for outcome in 0..<3 {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            let cache=PhoneSnapshotCache(directory:root),credentials=MemoryPhoneCredentials(),delayed=SuspendedPhoneClient()
            let old=PhoneRepository(cache:cache,credentials:credentials,client:delayed)
            try old.pair(pairing())
            let privateFeed=PhoneFixtures.feed()
            try cache.store(privateFeed,fetchedAt:Date())
            let request=Task {try await old.refresh()}
            await delayed.waitUntilStarted()
            let removed=PublishedWidgetFeed(publisherID:privateFeed.publisherID,publisherName:"Display",publishedAt:Date(),widgets:[])
            let current=PhoneRepository(cache:cache,credentials:credentials,client:ImmediatePhoneClient(feed:removed))
            _=try await current.refresh()
            if outcome==0 {await delayed.finish(.success(privateFeed))}
            else if outcome==1 {await delayed.finish(.failure(PhoneFetchError.unavailable))}
            else {await delayed.finish(.failure(PhoneFetchError.unauthorized))}
            let returned=try await request.value
            XCTAssertEqual(returned.state,.current)
            XCTAssertEqual(returned.feed?.widgets.count,0)
            XCTAssertNotNil(credentials.value)
            XCTAssertEqual(cache.load()?.widgets.count,0)
        }
    }
    func testActionFailurePreservesSnapshotAndSuccessfulActionUpdatesIt()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let cache=PhoneSnapshotCache(directory:root),credentials=MemoryPhoneCredentials()
        let original=PhoneFixtures.feed(),result=PublishedWidgetFeed(publisherID:original.publisherID,publisherName:"Display",publishedAt:Date(),widgets:[])
        credentials.value=try pairing();try cache.store(original,fetchedAt:Date())
        let command=AgentControlCommand(publisherID:original.publisherID,widgetID:original.widgets[0].id,rowID:"fixture",action:.reviewDone,revision:String(repeating:"a",count:64))
        let failed=PhoneRepository(cache:cache,credentials:credentials,client:RejectingPhoneClient(error:.unavailable))
        do {_=try await failed.perform(command);XCTFail("Must not confirm an unsupported action")} catch {}
        XCTAssertEqual(cache.load()?.widgets.count,1)
        let succeeded=PhoneRepository(cache:cache,credentials:credentials,client:ActionPhoneClient(feed:result))
        let snapshot=try await succeeded.perform(command)
        XCTAssertEqual(snapshot.feed?.widgets.count,0);XCTAssertEqual(cache.load()?.widgets.count,0)
    }
    func testSecondActionCannotSupersedeAnInFlightAction()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let cache=PhoneSnapshotCache(directory:root),credentials=MemoryPhoneCredentials(),client=SuspendedPhoneClient()
        credentials.value=try pairing();let feed=PhoneFixtures.feed();try cache.store(feed,fetchedAt:Date())
        let repository=PhoneRepository(cache:cache,credentials:credentials,client:client)
        let command=AgentControlCommand(publisherID:feed.publisherID,widgetID:feed.widgets[0].id,rowID:"fixture",action:.reviewDone,revision:String(repeating:"a",count:64))
        let first=Task {try await repository.perform(command)}
        await client.waitUntilStarted()
        do {_=try await repository.perform(command);XCTFail("Expected busy")} catch {XCTAssertEqual(error as? AgentControlError,.busy)}
        let result=PublishedWidgetFeed(publisherID:feed.publisherID,publisherName:"Display",publishedAt:Date(),widgets:[])
        await client.finish(.success(result))
        let applied=try await first.value
        XCTAssertEqual(applied.feed?.widgets.count,0)
    }
    func testActionResponseCannotRestoreContentAfterPairingChanges()async throws {
        for success in [true,false] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            let cache=PhoneSnapshotCache(directory:root),credentials=MemoryPhoneCredentials(),client=SuspendedPhoneClient()
            credentials.value=try pairing();let feed=PhoneFixtures.feed();try cache.store(feed,fetchedAt:Date())
            let old=PhoneRepository(cache:cache,credentials:credentials,client:client)
            let command=AgentControlCommand(publisherID:feed.publisherID,widgetID:feed.widgets[0].id,rowID:"fixture",action:.reviewDone,revision:String(repeating:"a",count:64))
            let task=Task {try await old.perform(command)};await client.waitUntilStarted()
            let new=PhoneRepository(cache:cache,credentials:credentials,client:ImmediatePhoneClient(feed:feed))
            try new.pair(pairing())
            if success {await client.finish(.success(feed))} else {await client.finish(.failure(PhoneFetchError.unauthorized))}
            do {_=try await task.value;XCTFail("Expected unconfirmed old action")} catch {XCTAssertEqual(error as? AgentControlError,.unconfirmed)}
            XCTAssertNotNil(credentials.value);XCTAssertNil(cache.load())
        }
    }
    func testExplicitRefreshAcknowledgesUnconfirmedActionButWidgetRefreshKeepsItVisible()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let cache=PhoneSnapshotCache(directory:root),credentials=MemoryPhoneCredentials(),feed=PhoneFixtures.feed()
        credentials.value=try pairing();try cache.store(feed,fetchedAt:Date())
        let failed=PhoneRepository(cache:cache,credentials:credentials,client:FailingActionClient())
        let command=AgentControlCommand(publisherID:feed.publisherID,widgetID:feed.widgets[0].id,rowID:"fixture",action:.reviewDone,revision:String(repeating:"a",count:64))
        do {_=try await failed.perform(command);XCTFail("Expected uncertainty")} catch {XCTAssertEqual(error as? AgentControlError,.unconfirmed)}
        XCTAssertTrue(try failed.snapshot().actionMessage?.contains("not confirmed")==true)
        let refreshing=PhoneRepository(cache:cache,credentials:credentials,client:ImmediatePhoneClient(feed:feed))
        let automatic=try await refreshing.refresh();XCTAssertNotNil(automatic.actionMessage)
        let explicit=try await refreshing.refresh(acknowledgingActionError:true);XCTAssertNil(explicit.actionMessage)
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

private struct ActionPhoneClient:PhoneFetching {
    let feed:PublishedWidgetFeed
    func fetch(_ pairing:PhonePairing)async throws->PublishedWidgetFeed {feed}
    func perform(_ command:AgentControlCommand,pairing:PhonePairing)async throws->PublishedWidgetFeed {feed}
}

private struct FailingActionClient:PhoneFetching {
    func fetch(_ pairing:PhonePairing)async throws->PublishedWidgetFeed {throw PhoneFetchError.unavailable}
    func perform(_ command:AgentControlCommand,pairing:PhonePairing)async throws->PublishedWidgetFeed {throw URLError(.networkConnectionLost)}
}
