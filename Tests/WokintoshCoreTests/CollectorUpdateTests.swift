import Foundation
import XCTest
@testable import WokintoshCore

final class CollectorUpdateTests: XCTestCase {
    private let bundled=CollectorInfo(version:"2.0.1",revision:String(repeating:"a",count:64))
    func testComparesRevisionAndDoesNotRecommendDowngradingANewerCollector() {
        XCTAssertEqual(CollectorUpdate.status(reported:bundled,bundled:bundled),.current)
        XCTAssertEqual(CollectorUpdate.status(reported:CollectorInfo(version:"2.0.0",revision:String(repeating:"b",count:64)),bundled:bundled),.updateAvailable)
        XCTAssertEqual(CollectorUpdate.status(reported:CollectorInfo(version:"2.0.1",revision:String(repeating:"b",count:64)),bundled:bundled),.updateAvailable)
        XCTAssertEqual(CollectorUpdate.status(reported:CollectorInfo(version:"2.0.10",revision:String(repeating:"b",count:64)),bundled:bundled),.newer)
        XCTAssertEqual(CollectorUpdate.status(reported:nil,bundled:bundled),.versionUnknown)
    }
    func testMatchingCollectorStillReportsItsSeparateObserverUpdate() {
        var info=bundled;info.observerStatus="updateAvailable"
        XCTAssertEqual(CollectorUpdate.status(reported:info,bundled:bundled),.observerUpdateAvailable)
        info.observerStatus="unavailable"
        XCTAssertEqual(CollectorUpdate.status(reported:info,bundled:bundled),.observerUnavailable)
        info.observerStatus="notInstalled"
        XCTAssertEqual(CollectorUpdate.status(reported:info,bundled:bundled),.current)
    }
    func testLegacyAndMalformedOptionalMetadataDoNotBreakHealthySnapshots() throws {
        let original=Snapshot(schemaVersion:1,host:HostInfo(id:"host",name:"Test",platform:"linux"),generatedAt:Date(),sessions:[],system:SystemReading())
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as? [String:Any])
        // Snapshot.decode uses ISO dates, so start from an explicit portable fixture.
        json["generatedAt"]="2026-11-24T12:00:00Z"
        for malformed:Any in [NSNull(),["version":17],["version":"2.0.1","revision":"short"],["version":"unexpected","revision":String(repeating:"a",count:64)]] {
            json["collector"]=malformed
            XCTAssertNil(try Snapshot.decode(JSONSerialization.data(withJSONObject:json)).collector)
        }
        json.removeValue(forKey:"collector")
        XCTAssertNil(try Snapshot.decode(JSONSerialization.data(withJSONObject:json)).collector)
        json["collector"]=["version":"2.0.1","revision":String(repeating:"b",count:64),"future":true]
        XCTAssertEqual(try Snapshot.decode(JSONSerialization.data(withJSONObject:json)).collector?.version,"2.0.1")
    }
}
