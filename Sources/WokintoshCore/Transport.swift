import Foundation
import Darwin

public enum RunnerError: LocalizedError {
    case unavailable, timedOut, oversized, failed(String)
    public var errorDescription: String? {
        switch self { case .unavailable: return "Collector unavailable"; case .timedOut: return "Connection timed out"; case .oversized: return "Collector response is too large"; case .failed(let message): return message }
    }
}

public enum CommandRunner {
    /// Call off the main actor. Files avoid pipe deadlocks and keep output bounded.
    public static func run(_ executable: String, arguments: [String], timeout: TimeInterval, maxBytes: Int = 16 * 1024 * 1024) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wokintosh-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("out")
        let errorURL = directory.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(max(0.01, timeout))
        func bytes(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        func stop() {
            if process.isRunning { process.terminate() }
            let grace = Date().addingTimeInterval(0.15)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        while process.isRunning {
            if bytes(outputURL) + bytes(errorURL) > maxBytes { stop(); throw RunnerError.oversized }
            if Date() >= deadline { stop(); throw RunnerError.timedOut }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if bytes(outputURL) + bytes(errorURL) > maxBytes { throw RunnerError.oversized }
        if process.terminationStatus != 0 {
            let message = String(data: (try? Data(contentsOf: errorURL)) ?? Data(), encoding: .utf8) ?? "Collector failed"
            throw RunnerError.failed(String(message.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try Data(contentsOf: outputURL)
    }
}

public enum RemoteCommand {
    public static func arguments(destination: String, collectorPath: String) -> [String]? {
        guard !destination.hasPrefix("-"), !destination.isEmpty,
              destination.range(of: #"^[A-Za-z0-9_.@:\[\]-]+$"#, options: .regularExpression) != nil,
              collectorPath.range(of: #"^(~/|/)[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil else { return nil }
        return ["-T", "-oBatchMode=yes", "-oConnectTimeout=7", "-oServerAliveInterval=3", "-oServerAliveCountMax=2", "--", destination, collectorPath + " snapshot --json"]
    }
}
