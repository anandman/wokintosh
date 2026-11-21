import XCTest
@testable import WokintoshCore
final class AgentControlRouteTests:XCTestCase {
    func testEarlierDoneRouteIsQualifiedAndRejectsExtraTargets() {
        let route=PhoneWidgetRoute(publisherID:UUID(),widgetID:UUID())
        XCTAssertEqual(PhoneWidgetRoute(url:route.url),route)
        let agents=PhoneWidgetRoute(publisherID:route.publisherID,widgetID:route.widgetID,section:.agents)
        XCTAssertEqual(PhoneWidgetRoute(url:agents.url),agents)
        XCTAssertNil(PhoneWidgetRoute(url:URL(string:route.url.absoluteString+"&target=codex://threads/other")!))
        XCTAssertNil(PhoneWidgetRoute(url:URL(string:"wokintosh://earlier?publisher=bad&widget=bad")!))
    }
}
