import Foundation
import XCTest
@testable import Wokintosh
@testable import WokintoshCore

@MainActor final class CollectorInstallationTests: XCTestCase {
    func testQueueShowsActiveAndWaitingMachinesAndContinuesAfterFailure() async {
        let first = RemoteHost(name: "Build Mac", destination: "build")
        let second = RemoteHost(name: "Linux", destination: "linux")
        let controller = CollectorInstallationController()
        var visited: [String] = []
        await controller.run([.remote(first), .remote(second), .localObserver]) { target, progress in
            visited.append(target.id)
            XCTAssertTrue(controller.isRunning)
            XCTAssertEqual(controller.activeTarget?.id, target.id)
            if target.id == first.id.uuidString {
                XCTAssertEqual(controller.entries[1].status, .queued)
                XCTAssertEqual(controller.entries[2].status, .queued)
                progress("Copying the collector…")
                XCTAssertEqual(controller.entries[0].status, .running("Copying the collector…"))
                return CollectorInstallationOutcome(details: "Installed; cleanup needs attention.", hasWarning: true)
            }
            if target.id == second.id.uuidString {
                XCTAssertEqual(controller.finishedCount, 1)
                throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "SSH unavailable"])
            }
            XCTAssertEqual(controller.finishedCount, 2)
            return CollectorInstallationOutcome(details: "Existing observer updated.")
        }
        XCTAssertEqual(visited, [first.id.uuidString, second.id.uuidString, "local"])
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.activeTarget)
        XCTAssertEqual(controller.finishedCount, 3)
        XCTAssertEqual(controller.updatedCount, 2)
        XCTAssertEqual(controller.warningCount, 1)
        XCTAssertEqual(controller.failedCount, 1)
        XCTAssertEqual(controller.entries[1].status, .failed("SSH unavailable"))
    }

    func testAnotherUpdateCannotReplaceAnActiveQueue() async {
        let host = RemoteHost(name: "Build Mac", destination: "build")
        let controller = CollectorInstallationController()
        await controller.run([.remote(host)]) { _, _ in
            await controller.run([.localObserver]) { _, _ in
                XCTFail("An overlapping update must not run")
                return CollectorInstallationOutcome(details: "Unexpected")
            }
            XCTAssertEqual(controller.entries.map(\.target.id), [host.id.uuidString])
            return CollectorInstallationOutcome(details: "Verified")
        }
        XCTAssertEqual(controller.updatedCount, 1)
    }

    func testLateProgressCannotReplaceAResultOrProgressFromANewerRun() async {
        let controller = CollectorInstallationController()
        var oldProgress: CollectorInstallationController.Progress?
        await controller.run([.localObserver]) { _, progress in
            oldProgress = progress
            return CollectorInstallationOutcome(details: "Verified")
        }
        oldProgress?("Late callback")
        XCTAssertEqual(controller.updatedCount, 1)
        await controller.run([.localObserver]) { _, progress in
            progress("Verifying…")
            oldProgress?("Old update callback")
            XCTAssertEqual(controller.entries[0].status, .running("Verifying…"))
            return CollectorInstallationOutcome(details: "Verified again")
        }
    }

    func testUpdateAllIncludesOnlyEligibleMachinesAndAnExistingOutdatedLocalObserver() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DashboardStore(dataDirectory: directory)
        store.document.previewMode = false
        let bundled = CollectorInfo(version: "2.0.4", revision: String(repeating: "a", count: 64))
        store.bundledCollectorInfo = bundled
        var local = bundled
        local.observerStatus = "updateAvailable"
        func feed(_ info: CollectorInfo?, online: Bool = true) -> FeedStatus {
            FeedStatus(name: "Fixture", snapshot: Snapshot(schemaVersion: 1,
                host: HostInfo(id: "fixture", name: "Fixture", platform: "macos"),
                generatedAt: Date(), sessions: [], system: SystemReading(), collector: info), error: online ? nil : "Offline")
        }
        store.feeds["local"] = feed(local)
        var eligibleIDs = ["local"]
        for (index, enabled, online, info) in [
            (0, true, true, Optional<CollectorInfo>.none),
            (1, true, true, CollectorInfo(version: "2.0.2", revision: String(repeating: "b", count: 64))),
            (2, true, true, bundled),
            (3, true, false, Optional<CollectorInfo>.none),
            (4, false, true, Optional<CollectorInfo>.none),
            (5, true, true, CollectorInfo(version: "2.1.0", revision: String(repeating: "b", count: 64)))] {
            var host = RemoteHost(name: "Fixture \(index)", destination: "fixture-\(index)")
            host.enabled = enabled
            store.document.remoteHosts.append(host)
            store.feeds[host.id.uuidString] = feed(info, online: online)
            if index < 2 { eligibleIDs.append(host.id.uuidString) }
        }
        XCTAssertEqual(store.collectorInstallationTargets.map(\.id), eligibleIDs)
        store.document.previewMode = true
        XCTAssertTrue(store.collectorInstallationTargets.isEmpty)
    }
}
