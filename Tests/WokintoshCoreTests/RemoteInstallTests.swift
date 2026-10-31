import Foundation
import XCTest
@testable import WokintoshCore

final class RemoteInstallTests: XCTestCase {
    private let snapshot = Data(#"{"schemaVersion":1,"host":{"id":"fixture-host","name":"Fixture","platform":"linux"},"generatedAt":"2026-10-30T10:00:00Z","sessions":[],"system":{}}"#.utf8)

    func testSuccessfulInstallUsesStrictSCPAndVerifiesBeforeAtomicPromotion() throws {
        let fixture = Fixture(snapshot: snapshot)
        let result = try RemoteInstall.run(destination: "dev@build-host", collectorPath: "~/.local/bin/wokintosh-agent", localCollectorPath: "/tmp/local collector.py", runner: { try fixture.run($0) })
        XCTAssertEqual(result.snapshot.host.id, "fixture-host")
        XCTAssertEqual(result.collectorPath, "/home/fixture user/.local/bin/wokintosh-agent")
        XCTAssertEqual(result.pythonVersion, "3.12.1")
        XCTAssertEqual(fixture.commands.map(\.executable), ["/usr/bin/ssh", "/usr/bin/ssh", "/usr/bin/scp", "/usr/bin/ssh", "/usr/bin/ssh", "/usr/bin/ssh", "/usr/bin/ssh"])
        let scp = fixture.commands[2]
        XCTAssertTrue(scp.arguments.contains("-B"))
        XCTAssertTrue(scp.arguments.contains("-oBatchMode=yes"))
        XCTAssertTrue(scp.arguments.contains("-oStrictHostKeyChecking=yes"))
        XCTAssertEqual(scp.arguments[scp.arguments.count - 2], "/tmp/local collector.py")
        XCTAssertTrue(scp.arguments.last!.hasPrefix("dev@build-host:'/home/fixture user/"))
        XCTAssertTrue(fixture.commands[3].arguments.last!.contains("subprocess.run"))
        XCTAssertTrue(fixture.commands[4].arguments.last!.contains("os.replace(candidate,target)"))
        for command in fixture.commands {
            XCTAssertGreaterThan(command.timeout, 0)
            XCTAssertLessThanOrEqual(command.timeout, 45)
            XCTAssertLessThanOrEqual(command.maxBytes, 16 * 1024 * 1024)
            XCTAssertTrue(command.arguments.contains("-oStrictHostKeyChecking=yes"))
        }
    }

    func testUnsupportedPythonNeverTransfersOrCreatesRemoteFolders() {
        let fixture = Fixture(snapshot: snapshot)
        fixture.probe = Data(#"{"home":"/home/fixture","python":"/usr/bin/python3","version":[3,9,9]}"#.utf8)
        XCTAssertThrowsError(try RemoteInstall.run(destination: "host", collectorPath: "~/bin/agent", localCollectorPath: "/tmp/collector", runner: { try fixture.run($0) }))
        XCTAssertEqual(fixture.commands.count, 1)
    }

    func testUntrustedPathsNeverRunSSH() {
        for (destination, path) in [("-oProxyCommand=touch", "~/bin/agent"), ("host;touch", "~/bin/agent"), ("host", "~/../agent"), ("host", "/tmp/a;touch"), ("host", "/tmp/agent/"), ("host", "~/"), ("user@@host", "~/bin/agent")] {
            let fixture = Fixture(snapshot: snapshot)
            XCTAssertThrowsError(try RemoteInstall.run(destination: destination, collectorPath: path, localCollectorPath: "/tmp/collector", runner: { try fixture.run($0) }))
            XCTAssertTrue(fixture.commands.isEmpty)
        }
    }

    func testSCPFailureCleansStagingWithoutPromoting() {
        let fixture = Fixture(snapshot: snapshot)
        fixture.failAt = 2
        XCTAssertThrowsError(try RemoteInstall.run(destination: "host", collectorPath: "~/bin/agent", localCollectorPath: "/tmp/collector", runner: { try fixture.run($0) }))
        XCTAssertEqual(fixture.commands.count, 4)
        XCTAssertTrue(fixture.commands.last!.arguments.last!.contains("shutil.rmtree"))
        XCTAssertFalse(fixture.commands.contains { $0.arguments.last!.contains("os.replace(candidate,target)") })
    }

    func testInvalidStagedProtocolNeverReplacesExistingCollector() {
        let fixture = Fixture(snapshot: Data("{\"schemaVersion\":99}".utf8))
        XCTAssertThrowsError(try RemoteInstall.run(destination: "host", collectorPath: "~/bin/agent", localCollectorPath: "/tmp/collector", runner: { try fixture.run($0) }))
        XCTAssertFalse(fixture.commands.contains { $0.arguments.last!.contains("os.replace(candidate,target)") })
        XCTAssertEqual(fixture.commands.count, 5)
    }

    func testFailedInstalledVerificationRunsRollbackBeforeCleanup() {
        let fixture = Fixture(snapshot: snapshot)
        fixture.failAt = 5
        XCTAssertThrowsError(try RemoteInstall.run(destination: "host", collectorPath: "~/bin/agent", localCollectorPath: "/tmp/collector", runner: { try fixture.run($0) }))
        XCTAssertEqual(fixture.commands.count, 8)
        XCTAssertTrue(fixture.commands[6].arguments.last!.contains("os.replace(backup,target)"))
        XCTAssertTrue(fixture.commands[7].arguments.last!.contains("shutil.rmtree"))
    }

    func testFailedRollbackKeepsRecoveryFilesAndExplainsBackup() {
        let fixture = Fixture(snapshot: snapshot)
        fixture.failAt = 5
        fixture.alsoFailAt = 6
        XCTAssertThrowsError(try RemoteInstall.run(destination: "host", collectorPath: "~/bin/agent", localCollectorPath: "/tmp/collector", runner: { try fixture.run($0) })) { error in
            XCTAssertTrue(error.localizedDescription.contains("Automatic rollback could not be confirmed"))
            XCTAssertTrue(error.localizedDescription.contains(".wokintosh-backup-"))
        }
        XCTAssertEqual(fixture.commands.count, 7)
    }

    func testIPv6AndHomeQuotesRemainOneSCPArgument() throws {
        let fixture = Fixture(snapshot: snapshot)
        fixture.probe = Data(#"{"home":"/home/fixture's space","python":"/opt/python3","version":[3,12,1]}"#.utf8)
        _ = try RemoteInstall.run(destination: "dev@[2001:db8::1]", collectorPath: "~/bin/agent", localCollectorPath: "/tmp/collector", runner: { try fixture.run($0) })
        XCTAssertTrue(fixture.commands[0].arguments.contains("dev@2001:db8::1"))
        XCTAssertTrue(fixture.commands[2].arguments.last!.hasPrefix("dev@[2001:db8::1]:"))
        XCTAssertTrue(fixture.commands[2].arguments.last!.contains("'\"'\"'"))
    }

    func testRealInstallScriptsKeepPreviousCollectorAndProviderSettingsInTemporaryFixture() throws {
        let fixture = try LocalScriptFixture(snapshot: snapshot)
        defer { fixture.remove() }
        let result = try RemoteInstall.run(destination: "fixture-only", collectorPath: "~/bin/agent", localCollectorPath: fixture.source.path, runner: { try fixture.run($0) })
        let backup = try XCTUnwrap(result.backupPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backup)), fixture.previous)
        XCTAssertTrue(try String(contentsOf: fixture.target, encoding: .utf8).hasPrefix("#!/usr/bin/python3\n"))
        XCTAssertEqual(try Data(contentsOf: fixture.settings), fixture.settingsContents)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path).contains { $0.hasPrefix(".wokintosh-install-") })
    }

    func testRealRollbackScriptRestoresPreviousBytesAfterInstalledCheckFails() throws {
        let fixture = try LocalScriptFixture(snapshot: snapshot)
        defer { fixture.remove() }
        fixture.failInstalledVerification = true
        XCTAssertThrowsError(try RemoteInstall.run(destination: "fixture-only", collectorPath: "~/bin/agent", localCollectorPath: fixture.source.path, runner: { try fixture.run($0) }))
        XCTAssertEqual(try Data(contentsOf: fixture.target), fixture.previous)
        XCTAssertEqual(try Data(contentsOf: fixture.settings), fixture.settingsContents)
    }

    func testDroppedPromotionBeforeStateCannotFinishAfterRollback() throws {
        try assertDroppedPromotionRestoresPreviousCollector(pausedBefore: "with open(os.path.join(stage,'state'),'x')")
    }

    func testDroppedPromotionBeforeReplacementCannotFinishAfterRollback() throws {
        try assertDroppedPromotionRestoresPreviousCollector(pausedBefore: "os.replace(candidate,target)")
    }

    func testRollbackCancelsPromotionThatHasNotAcquiredItsLock() throws {
        try assertDroppedPromotionRestoresPreviousCollector(pausedBefore: "with stage_lock(stage):")
    }

    private func assertDroppedPromotionRestoresPreviousCollector(pausedBefore marker: String) throws {
        let fixture = try LocalScriptFixture(snapshot: snapshot)
        defer { fixture.remove() }
        fixture.pausePromotionBefore = marker
        XCTAssertThrowsError(try RemoteInstall.run(destination: "fixture-only", collectorPath: "~/bin/agent", localCollectorPath: fixture.source.path, runner: { try fixture.run($0) }))
        XCTAssertTrue(fixture.sawConcurrentRollback)
        XCTAssertEqual(try Data(contentsOf: fixture.target), fixture.previous)
        XCTAssertEqual(try Data(contentsOf: fixture.settings), fixture.settingsContents)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.target.deletingLastPathComponent().path).contains { $0.hasPrefix(".wokintosh-install-") })
        let latePromotion = try XCTUnwrap(fixture.promotionCommand)
        XCTAssertThrowsError(try CommandRunner.run("/bin/sh", arguments: ["-c", latePromotion], timeout: 3))
        XCTAssertEqual(try Data(contentsOf: fixture.target), fixture.previous)
    }

    private final class LocalScriptFixture: @unchecked Sendable {
        let directory: URL
        let source: URL
        let target: URL
        let settings: URL
        let previous = Data("#!/usr/bin/env python3\n# previous collector\n".utf8)
        let settingsContents = Data("existing provider hooks and state must be preserved".utf8)
        var firstCommand = true
        var failInstalledVerification = false
        var pausePromotionBefore: String?
        var pendingPromotion: (process: Process, stage: URL)?
        var promotionCommand: String?
        var sawConcurrentRollback = false

        init(snapshot: Data) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("wokintosh-install fixture's-" + UUID().uuidString)
            source = directory.appendingPathComponent("bundled collector.py")
            target = directory.appendingPathComponent("bin/agent")
            settings = directory.appendingPathComponent(".codex/config.toml")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let json = String(data: snapshot, encoding: .utf8)!
            try Data(("#!/usr/bin/env python3\nprint(" + "\"" + json.replacingOccurrences(of: "\"", with: "\\\"") + "\"" + ")\n").utf8).write(to: source)
            try previous.write(to: target)
            try settingsContents.write(to: settings)
        }

        func remove() {
            if let pendingPromotion, pendingPromotion.process.isRunning {
                try? Data().write(to: pendingPromotion.stage.appendingPathComponent("fixture-release"))
                pendingPromotion.process.terminate()
                pendingPromotion.process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        func run(_ command: RemoteInstallCommand) throws -> Data {
            // This executes only the generated scripts under our temporary HOME fixture.
            // No SSH/SCP executable is ever launched.
            if firstCommand {
                firstCommand = false
                return try JSONSerialization.data(withJSONObject: ["home": directory.path, "python": "/usr/bin/python3", "version": [3, 12, 1]])
            }
            let remote = command.arguments.last!
            if command.executable == "/usr/bin/scp" {
                let quotedPath = String(remote.dropFirst("fixture-only:".count))
                return try CommandRunner.run("/bin/sh", arguments: ["-c", "cp -- " + RemoteCommand.shellQuote(source.path) + " " + quotedPath], timeout: 3)
            }
            if failInstalledVerification && remote.contains("subprocess.run([target") { throw RunnerError.failed("Fixture installed verification failed") }
            if let marker = pausePromotionBefore, remote.contains("os.replace(candidate,target)") {
                promotionCommand = remote
                let arguments = try JSONDecoder().decode([String].self, from: CommandRunner.run("/usr/bin/python3", arguments: ["-c", "import json,shlex,sys;print(json.dumps(shlex.split(sys.argv[1])))", remote], timeout: 3))
                let script = arguments[2]
                let line = try XCTUnwrap(script.components(separatedBy: "\n").first { $0.contains(marker) })
                let indentation = String(line.prefix { $0 == " " })
                let pause = """
                import time
                open(os.path.join(stage,'fixture-paused'),'x').close()
                deadline=time.monotonic()+5
                while not os.path.exists(os.path.join(stage,'fixture-release')):
                    if time.monotonic()>deadline: raise SystemExit('Fixture pause timed out')
                    time.sleep(0.01)
                """.components(separatedBy: "\n").map { indentation + $0 }.joined(separator: "\n")
                let modified = script.replacingOccurrences(of: line, with: pause + "\n" + line)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = ["-c", modified] + arguments.dropFirst(3)
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                let stage = URL(fileURLWithPath: arguments[4])
                pendingPromotion = (process, stage)
                let deadline = Date().addingTimeInterval(3)
                while !FileManager.default.fileExists(atPath: stage.appendingPathComponent("fixture-paused").path), process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                guard FileManager.default.fileExists(atPath: stage.appendingPathComponent("fixture-paused").path) else { throw RunnerError.failed("Fixture promotion did not pause") }
                throw RunnerError.timedOut
            }
            if remote.contains("os.replace(backup,target)"), let pendingPromotion {
                sawConcurrentRollback = pendingPromotion.process.isRunning
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    try? Data().write(to: pendingPromotion.stage.appendingPathComponent("fixture-release"))
                }
                let result = try CommandRunner.run("/bin/sh", arguments: ["-c", remote], timeout: 3, maxBytes: command.maxBytes)
                let deadline = Date().addingTimeInterval(3)
                while pendingPromotion.process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                XCTAssertFalse(pendingPromotion.process.isRunning)
                if !pendingPromotion.process.isRunning { XCTAssertEqual(pendingPromotion.process.terminationStatus, pausePromotionBefore == "with stage_lock(stage):" ? 1 : 0) }
                return result
            }
            return try CommandRunner.run("/bin/sh", arguments: ["-c", remote], timeout: 3, maxBytes: command.maxBytes)
        }
    }

    // A command fixture only: it never spawns SSH/SCP or reads an actual host.
    private final class Fixture: @unchecked Sendable {
        var commands: [RemoteInstallCommand] = []
        var probe = Data(#"{"home":"/home/fixture user","python":"/opt/python3","version":[3,12,1]}"#.utf8)
        var snapshot: Data
        var failAt: Int?
        var alsoFailAt: Int?
        init(snapshot: Data) { self.snapshot = snapshot }
        func run(_ command: RemoteInstallCommand) throws -> Data {
            let index = commands.count
            commands.append(command)
            if index == failAt || index == alsoFailAt { throw RunnerError.failed("Fixture command failure") }
            if index == 0 { return probe }
            if command.arguments.last!.contains("os.replace(candidate,target)") { return Data("{\"backupPath\":null}".utf8) }
            if command.arguments.last!.contains("subprocess.run") || command.arguments.last!.hasSuffix(" snapshot --json") { return snapshot }
            return Data()
        }
    }
}
