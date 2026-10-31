import Foundation
import XCTest
@testable import WokintoshCore

final class DisplayPreferenceTests: XCTestCase {
    func testHiddenDockPreferenceSurvivesSaveAndReload() throws {
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DashboardDocument.defaultLayout)) as! [String: Any]
        legacy["showDockIcon"] = false
        let loaded = try JSONDecoder().decode(DashboardDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as! [String: Any]
        XCTAssertEqual(saved["showDockIcon"] as? Bool, false)
    }

    func testOlderLayoutsKeepDockIconVisibleOnUpgrade() throws {
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DashboardDocument.defaultLayout)) as! [String: Any]
        legacy.removeValue(forKey: "showDockIcon")
        let loaded = try JSONDecoder().decode(DashboardDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as! [String: Any]
        XCTAssertEqual(saved["showDockIcon"] as? Bool, true)
    }
}
