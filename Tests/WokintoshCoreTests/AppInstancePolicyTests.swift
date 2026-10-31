import XCTest
@testable import WokintoshCore

final class AppInstancePolicyTests:XCTestCase {
    func testFindsExistingCopyWithoutRejectingSelfOrOtherApps() {
        let running=[RunningAppInstance(pid:10,bundleID:"app"),RunningAppInstance(pid:20,bundleID:"app"),RunningAppInstance(pid:30,bundleID:"qa"),RunningAppInstance(pid:40,bundleID:nil)]
        XCTAssertEqual(AppInstancePolicy.otherCopies(currentPID:10,bundleID:"app",running:running).map(\.pid),[20])
    }
    func testOlderCopyIsOfferedFirstToPreserveCurrentLayoutOnQuit() {
        let running=[RunningAppInstance(pid:30,bundleID:"app",launchedAt:Date(timeIntervalSince1970:30)),RunningAppInstance(pid:20,bundleID:"app",launchedAt:Date(timeIntervalSince1970:20))]
        XCTAssertEqual(AppInstancePolicy.otherCopies(currentPID:10,bundleID:"app",running:running).map(\.pid),[20,30])
    }
    func testMissingBundleIdentityDoesNotBlockStandaloneTools() {
        XCTAssertTrue(AppInstancePolicy.otherCopies(currentPID:10,bundleID:nil,running:[RunningAppInstance(pid:20,bundleID:nil)]).isEmpty)
    }
}
