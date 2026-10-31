import Foundation
import XCTest
@testable import WokintoshCore

final class WidgetActionTests:XCTestCase {
    private func encoded(_ widget:Widget) throws -> [String:Any] {
        try JSONSerialization.jsonObject(with:JSONEncoder().encode(widget)) as! [String:Any]
    }
    func testOlderWidgetsStayInertAfterUpgrade() throws {
        var input=try encoded(Widget(kind:.weather,frame:WidgetFrame(x:0.1,y:0.2,width:0.3,height:0.4)))
        input.removeValue(forKey:"action")
        let loaded=try JSONDecoder().decode(Widget.self,from:JSONSerialization.data(withJSONObject:input))
        let saved=try encoded(loaded)
        XCTAssertEqual((saved["action"] as? [String:Any])?["kind"] as? String,"none")
        XCTAssertEqual(loaded.frame.x,0.1)
        XCTAssertEqual(loaded.kind,.weather)
    }
    func testDuplicateWidgetKindsKeepIndependentApplicationAndLinkActions() throws {
        var first=try encoded(Widget(kind:.weather,frame:WidgetFrame(x:0.1,y:0.2,width:0.3,height:0.4)))
        var second=try encoded(Widget(kind:.weather,frame:WidgetFrame(x:0.5,y:0.2,width:0.3,height:0.4)))
        first["action"]=["kind":"openApplication","applicationBundleID":"test.weather","applicationName":"Weather App"]
        second["action"]=["kind":"openURL","url":"https://example.com/weather?city=Paris#today"]
        let loaded=try JSONDecoder().decode([Widget].self,from:JSONSerialization.data(withJSONObject:[first,second]))
        let saved=try loaded.map{try encoded($0)}
        let app=saved[0]["action"] as? [String:Any],link=saved[1]["action"] as? [String:Any]
        XCTAssertEqual(app?["applicationBundleID"] as? String,"test.weather")
        XCTAssertEqual(link?["url"] as? String,"https://example.com/weather?city=Paris#today")
        XCTAssertEqual(loaded[0].frame.x,0.1);XCTAssertEqual(loaded[1].frame.x,0.5)
        XCTAssertNotEqual(loaded[0].id,loaded[1].id)
    }
    func testUnknownActionIsDisabledWithoutResettingWidget() throws {
        var input=try encoded(Widget(kind:.system,frame:WidgetFrame(x:0.2,y:0.3,width:0.4,height:0.5)))
        input["hostID"]="remote-host"
        input["action"]=["kind":"future-action","url":"https://example.com"]
        let loaded=try JSONDecoder().decode(Widget.self,from:JSONSerialization.data(withJSONObject:input))
        XCTAssertEqual((try encoded(loaded)["action"] as? [String:Any])?["kind"] as? String,"none")
        XCTAssertEqual(loaded.hostID,"remote-host");XCTAssertEqual(loaded.frame.height,0.5)
    }
    func testOnlyTheSelectedTargetCanLaunch() throws {
        let inert=WidgetAction(kind:.none,applicationBundleID:"test.app",url:"https://example.com")
        XCTAssertNil(try inert.target())
        let app=WidgetAction(kind:.openApplication,applicationBundleID:" test.app ",url:"https://example.com")
        XCTAssertEqual(try app.target(),.application(bundleID:"test.app"))
        XCTAssertThrowsError(try WidgetAction(kind:.openApplication,applicationBundleID:" ").target())
        XCTAssertThrowsError(try WidgetAction(kind:.openApplication,applicationBundleID:"test.app --flag").target())
    }
    func testAgentTargetsRespectHarnessAndCustomChoices() throws {
        var action=WidgetAction(kind:.openAgentApp)
        action.codexBundleID="test.codex";action.claudeBundleID="test.claude"
        XCTAssertEqual(try action.target(provider:"codex"),.application(bundleID:"test.codex"))
        XCTAssertEqual(try action.target(provider:"claude"),.application(bundleID:"test.claude"))
        XCTAssertThrowsError(try action.target(provider:nil))
        XCTAssertThrowsError(try action.target(provider:"unknown"))
    }
    func testWebAndApplicationLinksPreserveDestinationWhileRejectingInvalidInput() throws {
        XCTAssertEqual(try WidgetAction(kind:.openURL,url:"https://example.com/weather?city=Paris#today").target(),.link(URL(string:"https://example.com/weather?city=Paris#today")!))
        XCTAssertEqual(try WidgetAction(kind:.openURL,url:"weather-example://forecast").target(),.link(URL(string:"weather-example://forecast")!))
        for value in ["", "not a link", "https://", "javascript:alert(1)", "data:text/html,a", "file:///tmp/a", "https://exa\nmple.com"] {
            XCTAssertThrowsError(try WidgetAction(kind:.openURL,url:value).target(),value)
        }
    }

}
