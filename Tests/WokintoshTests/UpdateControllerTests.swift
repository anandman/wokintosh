import XCTest
import Sparkle
@testable import Wokintosh

final class UpdateControllerTests: XCTestCase {
    @MainActor func testCheckCannotRunBeforeStartOrWhileAnotherCheckIsActive() {
        let driver = UpdateTestDriver()
        let controller = UpdateController(driver: driver)
        controller.checkForUpdates()
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertEqual(driver.checks, 0)
        controller.start()
        XCTAssertTrue(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
        XCTAssertFalse(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
    }

    @MainActor func testStartIsIdempotentAndFailureLeavesActionUnavailable() {
        let driver = UpdateTestDriver()
        driver.startError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot start updater"])
        let controller = UpdateController(driver: driver)
        controller.start()
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertEqual(controller.state.issue, "Cannot start updater")
        driver.startError = nil
        controller.start()
        controller.start()
        XCTAssertTrue(controller.canCheckForUpdates)
        XCTAssertEqual(driver.starts, 2)
    }

    @MainActor func testPreferencesStayWithDriverAndExternalChangesReachSettings() {
        let driver = UpdateTestDriver()
        let first = UpdateController(driver: driver)
        first.start()
        first.setAutomaticallyChecks(false)
        XCTAssertFalse(first.state.automaticallyChecks)
        XCTAssertTrue(first.state.automaticallyDownloads)
        first.setAutomaticallyDownloads(false)
        let reopened = UpdateController(driver: driver)
        reopened.start()
        XCTAssertFalse(reopened.state.automaticallyChecks)
        XCTAssertFalse(reopened.state.automaticallyDownloads)
        driver.state.automaticallyChecks = true
        driver.state.automaticallyDownloads = true
        driver.onChange?()
        XCTAssertTrue(reopened.state.automaticallyChecks)
        XCTAssertTrue(reopened.state.automaticallyDownloads)
    }

    @MainActor func testReminderRemainsUntilActualUpdateSessionEnds() {
        let driver = UpdateTestDriver()
        let controller = UpdateController(driver: driver)
        controller.start()
        driver.state.availableVersion = "1.2.0"
        driver.onChange?()
        XCTAssertEqual(controller.menuTitle, "Update Available…")
        XCTAssertEqual(controller.state.availableVersion, "1.2.0")
        driver.state.lastCheck = Date(timeIntervalSince1970: 1234)
        driver.onChange?()
        XCTAssertEqual(controller.state.availableVersion, "1.2.0")
        XCTAssertEqual(controller.state.lastCheck, Date(timeIntervalSince1970: 1234))
        driver.state.availableVersion = nil
        driver.onChange?()
        XCTAssertEqual(controller.menuTitle, "Check for Updates…")
    }

    @MainActor func testSkippingPreparedUpdateClearsReminderButDismissKeepsInstallOnQuit() {
        let driver = SparkleUpdateDriver()
        let controller = UpdateController(driver: driver)
        // Starting Sparkle would access network/defaults. Exercise its actual delegate
        // callbacks without starting it; these are the production reminder boundaries.
        let item = SUAppcastItem(dictionary: ["title": "Version 1.2.0", "sparkle:version": "14", "sparkle:shortVersionString": "1.2.0", "enclosure": ["url": "https://example.org/Wokintosh.dmg", "length": "123", "type": "application/octet-stream"]], relativeTo: nil, failureReason: nil)!
        let state = SPUUserUpdateState(coder: PreparedUpdateDecoder())!
        _ = driver.updater(driver.sparkleUpdater, willInstallUpdateOnQuit: item, immediateInstallationBlock: {})
        XCTAssertTrue(controller.state.readyToInstall)
        driver.updater(driver.sparkleUpdater, userDidMake: .dismiss, forUpdate: item, state: state)
        driver.standardUserDriverWillFinishUpdateSession()
        XCTAssertTrue(controller.state.readyToInstall)
        XCTAssertEqual(controller.state.availableVersion, "1.2.0")
        driver.updater(driver.sparkleUpdater, userDidMake: .skip, forUpdate: item, state: state)
        driver.standardUserDriverWillFinishUpdateSession()
        XCTAssertFalse(controller.state.readyToInstall)
        XCTAssertNil(controller.state.availableVersion)
        XCTAssertEqual(controller.menuTitle, "Check for Updates…")
    }

    @MainActor func testInstallationFailureClearsPreparedReminderWhileNetworkFailureKeepsIt() {
        for code in [4005, 4007, 2001] {
            let driver = SparkleUpdateDriver()
            let controller = UpdateController(driver: driver)
            let item = SUAppcastItem(dictionary: ["title": "Version 1.2.0", "sparkle:version": "14", "sparkle:shortVersionString": "1.2.0", "enclosure": ["url": "https://example.org/Wokintosh.dmg", "length": "123", "type": "application/octet-stream"]], relativeTo: nil, failureReason: nil)!
            _ = driver.updater(driver.sparkleUpdater, willInstallUpdateOnQuit: item, immediateInstallationBlock: {})
            driver.updater(driver.sparkleUpdater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "Controlled failure"]))
            XCTAssertEqual(controller.state.readyToInstall, code == 2001, "error code \(code)")
            XCTAssertEqual(controller.state.issue, "Controlled failure")
        }
    }

    @MainActor func testUnconfiguredBundleCannotScheduleChecksOrShowUpdateUI() {
        let controller = UpdateController(bundle: Bundle(for: Self.self))
        controller.start()
        controller.checkForUpdates()
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertNotNil(controller.state.unavailableReason)
    }
}

@MainActor private final class UpdateTestDriver: UpdateDriving {
    var state = UpdateState(canCheck: true, automaticallyChecks: true, automaticallyDownloads: true)
    var onChange: (() -> Void)?
    var starts = 0
    var checks = 0
    var startError: Error?
    func start() throws { starts += 1; if let startError { throw startError } }
    func checkForUpdates() { checks += 1; state.canCheck = false; onChange?() }
    func setAutomaticallyChecks(_ enabled: Bool) { state.automaticallyChecks = enabled; onChange?() }
    func setAutomaticallyDownloads(_ enabled: Bool) { state.automaticallyDownloads = enabled; onChange?() }
}

/// Sparkle exposes secure decoding, but no public stage initializer.
private final class PreparedUpdateDecoder: NSCoder {
    override var allowsKeyedCoding: Bool { true }
    override func decodeInteger(forKey key: String) -> Int { SPUUserUpdateStage.installing.rawValue }
    override func decodeBool(forKey key: String) -> Bool { true }
}
