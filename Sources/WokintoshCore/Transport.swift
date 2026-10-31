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
    public static func isValidDestination(_ destination: String) -> Bool {
        guard !destination.isEmpty, destination.utf8.count <= 255 else { return false }
        let parts = destination.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        if parts.count == 2, parts[0].range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) == nil { return false }
        var host = String(parts.last!)
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") {
            return host.filter { $0 == ":" }.count >= 2 && host.range(of: #"^[A-Fa-f0-9:.]+(%[A-Za-z0-9_.-]+)?$"#, options: .regularExpression) != nil
        }
        return host.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    public static func isValidCollectorPath(_ path: String) -> Bool {
        guard path.utf8.count <= 4096,
              path.range(of: #"^(~/|/)[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil else { return false }
        let suffix = path.hasPrefix("~/") ? String(path.dropFirst(2)) : String(path.dropFirst())
        return !suffix.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    public static func arguments(destination: String, collectorPath: String) -> [String]? {
        guard isValidDestination(destination), isValidCollectorPath(collectorPath) else { return nil }
        let path = collectorPath.hasPrefix("~/") ? "\"$HOME\"/" + shellQuote(String(collectorPath.dropFirst(2))) : shellQuote(collectorPath)
        return sshArguments(destination: destination, command: path + " snapshot --json")
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    static func sshArguments(destination: String, command: String) -> [String] {
        // SSH accepts unbracketed IPv6; SCP requires brackets around its host component.
        let sshDestination = destination.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        return ["-T", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oConnectTimeout=7", "-oServerAliveInterval=3", "-oServerAliveCountMax=2", "--", sshDestination, command]
    }

    static func scpDestination(_ destination: String) -> String {
        let parts = destination.split(separator: "@", omittingEmptySubsequences: false)
        let host = String(parts.last!).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        return (parts.count == 2 ? String(parts[0]) + "@" : "") + (host.contains(":") ? "[" + host + "]" : host)
    }
}
