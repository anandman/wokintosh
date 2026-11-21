import Foundation

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

    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    public static func sshArguments(destination: String, command: String) -> [String] {
        // SSH accepts unbracketed IPv6; SCP requires brackets around its host component.
        let sshDestination = destination.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        return ["-T", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oConnectTimeout=7", "-oServerAliveInterval=3", "-oServerAliveCountMax=2", "--", sshDestination, command]
    }

    public static func scpDestination(_ destination: String) -> String {
        let parts = destination.split(separator: "@", omittingEmptySubsequences: false)
        let host = String(parts.last!).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        return (parts.count == 2 ? String(parts[0]) + "@" : "") + (host.contains(":") ? "[" + host + "]" : host)
    }
}
