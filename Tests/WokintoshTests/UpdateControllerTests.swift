import XCTest
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
