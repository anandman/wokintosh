import Foundation
import XCTest
@testable import WokintoshCore

final class DisplayPreferenceTests: XCTestCase {
    func testLockedDisplayExperimentDefaultsOffForNewAndOlderLayouts() throws {
        let fresh = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DashboardDocument.defaultLayout)) as! [String: Any]
        XCTAssertEqual(fresh["experimentalLockedDisplay"] as? Bool, false)
        var legacy = fresh
        legacy.removeValue(forKey: "experimentalLockedDisplay")
        let loaded = try JSONDecoder().decode(DashboardDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as! [String: Any]
        XCTAssertEqual(saved["experimentalLockedDisplay"] as? Bool, false)
    }

    func testLockedDisplayExperimentRoundTripsWithoutChangingPresentationChoices() throws {
        for enabled in [true, false] {
            var input = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DashboardDocument.defaultLayout)) as! [String: Any]
            input["experimentalLockedDisplay"] = enabled
            input["nativeFullscreen"] = false
            input["displayID"] = 12345
            input["showDockIcon"] = false
            input["presentationEnabled"] = true
            let loaded = try JSONDecoder().decode(DashboardDocument.self, from: JSONSerialization.data(withJSONObject: input))
            let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as! [String: Any]
            XCTAssertEqual(saved["experimentalLockedDisplay"] as? Bool, enabled)
            XCTAssertEqual(saved["nativeFullscreen"] as? Bool, false)
            XCTAssertEqual(saved["displayID"] as? UInt32, 12345)
            XCTAssertEqual(saved["showDockIcon"] as? Bool, false)
            XCTAssertEqual(saved["presentationEnabled"] as? Bool, true)
        }
    }

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
