import XCTest
@testable import WokintoshCore

final class SessionLinksTests:XCTestCase {
    func session(_ links:Any?=nil) throws -> AgentSession {
        var value:[String:Any] = ["id":"thread", "provider":"codex", "title":"Example", "project":"example", "state":"working", "updatedAt":0]
        if let links {value["openURLs"]=links}
        return try JSONDecoder().decode(AgentSession.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testOldSessionsDecodeWithoutInventedLinks() throws {
        XCTAssertNil(try session().openURLs)
    }
    func testPlatformTargetsRoundTripAndUnknownFieldsAreHarmless() throws {
        let s=try session(["iOS":["primary":"codex://threads/example", "fallback":"https://chatgpt.com/app"],"futureOS":"something"])
        XCTAssertEqual(s.openURLs?.iOS?.primary,"codex://threads/example")
        XCTAssertNil(s.openURLs?.macOS)
        XCTAssertEqual(try JSONDecoder().decode(AgentSession.self,from:JSONEncoder().encode(s)),s)
    }
    func testMalformedOptionalTargetsCannotDiscardHealthySessionsOrOtherPlatform() throws {
        for bad:Any in [NSNull(),[],"bad",["primary":"file:///tmp/private"],["primary":"https://user:password@example.com"],["primary":"javascript:alert(1)"]] {
            let s=try session(["iOS":bad,"macOS":["primary":"codex://threads/example"]])
            XCTAssertEqual(s.title,"Example")
            XCTAssertNil(s.openURLs?.iOS)
            XCTAssertNotNil(s.openURLs?.macOS)
        }
        XCTAssertNil(try session([1,2,3]).openURLs)
    }
    func testTargetsRejectActionsAndUnboundedOrMalformedInputs() {
        for input in ["", "https://", "https://user:p@example.com", "codex://threads/a\nb", "tel:123", "data:text/plain,a", "file:///tmp/a", "https://example.com/"+String(repeating:"a",count:4096)] {
            XCTAssertNil(SessionOpenTarget.validURL(input),input)
        }
        XCTAssertEqual(SessionOpenTarget.validURL("claude://code/session_abc")?.scheme,"claude")
    }
}
