import Foundation
import XCTest
@testable import WokintoshCore

private final class PhoneFixtureProtocol:URLProtocol {
    static var status=200
    static var bytes=Data()
    static var lastRequest:URLRequest?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        Self.lastRequest=request
        let response=HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PhoneFeedClientTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1800000000)
    func feed()->PublishedWidgetFeed {PublishedWidgetFeed(publisherID:UUID(),publisherName:"Display",publishedAt:now,widgets:[])}
    func client()->PhoneFeedClient {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[PhoneFixtureProtocol.self]
        return PhoneFeedClient(configuration:config)
    }
    func pairing()throws->PhonePairing {try PhonePairing(endpoint:"https://display.example.ts.net:9443/wokintosh/v1/widgets",token:String(repeating:"A",count:43))}
    func testFetchingUsesHeaderAuthenticationWithoutPuttingCredentialInURL() async throws {
        let expected=feed();PhoneFixtureProtocol.status=200;PhoneFixtureProtocol.bytes=try expected.encoded()
        let received=try await client().fetch(pairing())
        XCTAssertEqual(received.publisherID,expected.publisherID)
        let request=try XCTUnwrap(PhoneFixtureProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer "+String(repeating:"A",count:43))
        XCTAssertNil(request.url?.query)
    }
    func testAgentCommandUsesPrivatePostAndConflictIsNotPairingRevocation()async throws {
        let expected=feed();PhoneFixtureProtocol.status=200;PhoneFixtureProtocol.bytes=try expected.encoded()
        let command=AgentControlCommand(publisherID:expected.publisherID,widgetID:UUID(),rowID:"host:codex:fixture",action:.reviewDone,revision:String(repeating:"a",count:64))
        _=try await client().perform(command,pairing:pairing())
        XCTAssertEqual(PhoneFixtureProtocol.lastRequest?.httpMethod,"POST")
        XCTAssertEqual(PhoneFixtureProtocol.lastRequest?.url?.path,"/wokintosh/v1/agent-actions")
        for status in [403,409] {
            PhoneFixtureProtocol.status=status
            do {_=try await client().perform(command,pairing:pairing());XCTFail("Expected rejection")}
            catch {XCTAssertEqual(error as? AgentControlError,status==409 ? .conflict : .disabled)}
        }
    }
    func testAuthorizationFailureIsDistinctFromTemporaryServerFailure() async throws {
        for status in [401,403,503,302] {
            PhoneFixtureProtocol.status=status;PhoneFixtureProtocol.bytes=Data()
            do {_ = try await client().fetch(pairing());XCTFail("Expected HTTP rejection")} catch {
                XCTAssertEqual(error as? PhoneFetchError,status==401 || status==403 ? .unauthorized : .unavailable)
            }
        }
    }
    func testStreamingRejectsOversizedResponsesEvenWithoutContentLength() async throws {
        PhoneFixtureProtocol.status=200;PhoneFixtureProtocol.bytes=Data(repeating:32,count:PublishedWidgetFeed.maximumBytes+1)
        do {_ = try await client().fetch(pairing());XCTFail("Expected size rejection")} catch {
            XCTAssertEqual(error as? PhoneFetchError,.oversized)
        }
    }
    func testNetworkFailureRetainsOriginalCacheTimeButAuthFailureClearsContent() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let cache=PhoneSnapshotCache(directory:directory),expected=feed()
        try cache.store(expected,fetchedAt:now)
        try cache.markUnavailable()
        XCTAssertEqual(cache.load()?.publisherID,expected.publisherID)
        XCTAssertEqual(cache.status().state,.offline)
        XCTAssertEqual(cache.status().lastFetchedAt,now)
        try cache.requirePairing()
        XCTAssertNil(cache.load())
        XCTAssertEqual(cache.status().state,.authorizationRequired)
        XCTAssertNil(cache.status().lastFetchedAt)
    }
    func testCorruptOrOversizedCacheNeverBecomesAUsableFeed() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let cache=PhoneSnapshotCache(directory:directory)
        try cache.store(feed(),fetchedAt:now)
        let file=directory.appendingPathComponent("feed.json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        try Data(repeating:65,count:PublishedWidgetFeed.maximumBytes+1).write(to:file)
        XCTAssertNil(cache.load())
        try cache.clear()
        XCTAssertEqual(cache.status().state,.unpaired)
    }
}
