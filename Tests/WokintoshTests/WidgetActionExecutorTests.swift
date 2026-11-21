import XCTest
import WokintoshCore
@testable import Wokintosh

final class WidgetActionExecutorTests:XCTestCase {
    @MainActor func testUnavailablePrimaryUsesBackupAndStopsOnSuccess() async throws {
        var attempts:[String]=[]
        let executor=WidgetActionExecutor(launchApplication:{attempts.append($0)},launchURL:{url in
            attempts.append(url.absoluteString);return url.scheme == "https"
        })
        try await executor.open([.link(URL(string:"claude://code/example")!),.link(URL(string:"https://claude.ai/code/example")!),.application(bundleID:"test.unused")])
        XCTAssertEqual(attempts,["claude://code/example","https://claude.ai/code/example"])
    }
    @MainActor func testUnavailableSessionURLRetainsConfiguredAppFallback() async throws {
        var applications:[String]=[]
        let executor=WidgetActionExecutor(launchApplication:{applications.append($0)},launchURL:{_ in false})
        let session=AgentSession(id:"example",provider:"codex",title:"Example",project:"example",state:.working,updatedAt:Date(),openURLs:SessionOpenURLs(macOS:SessionOpenTarget(primary:"codex://threads/example")))
        var action=WidgetAction(kind:.openAgentApp);action.codexBundleID="test.custom.codex"
        try await executor.open(action.targets(provider:"codex",session:session))
        XCTAssertEqual(applications,["test.custom.codex"])
    }
}
