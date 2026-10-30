import XCTest
@testable import WokintoshCore
final class TransportTests: XCTestCase {
    func testRunnerCapturesOutput() throws {
        XCTAssertEqual(String(data: try CommandRunner.run("/bin/echo", arguments: ["snapshot"], timeout: 1), encoding: .utf8), "snapshot\n")
    }
    func testRunnerTimesOut() {
        let start = Date()
        XCTAssertThrowsError(try CommandRunner.run("/bin/sleep", arguments: ["2"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
    func testRunnerRejectsExcessiveOutput() {
        XCTAssertThrowsError(try CommandRunner.run("/usr/bin/yes", arguments: [], timeout: 1, maxBytes: 1024))
    }
    func testSSHDoesNotAcceptOptionsOrShellSyntaxAsHost() {
        XCTAssertNil(RemoteCommand.arguments(destination: "-oProxyCommand=bad", collectorPath: "~/.local/bin/wokintosh-agent"))
        XCTAssertNil(RemoteCommand.arguments(destination: "host; touch /tmp/bad", collectorPath: "~/.local/bin/wokintosh-agent"))
        XCTAssertNil(RemoteCommand.arguments(destination: "dev-mini", collectorPath: "/tmp/a;echo bad"))
        XCTAssertNotNil(RemoteCommand.arguments(destination: "anand@dev-mini", collectorPath: "~/.local/bin/wokintosh-agent"))
    }
}
