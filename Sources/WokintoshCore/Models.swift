import Foundation
public enum AgentState: String, Codable, CaseIterable, Sendable {
    case working, needsAttention, idle, finished, unknown
    public init(from decoder: Decoder) throws { self = AgentState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
}
public struct AgentSession: Codable, Equatable, Sendable {
    public var id: String; public var provider: String; public var title: String; public var project: String
    public var state: AgentState; public var updatedAt: Date; public var activity: String?; public var parentId: String?
    public init(id: String, provider: String, title: String, project: String, state: AgentState, updatedAt: Date, activity: String? = nil, parentId: String? = nil) {
        self.id=id; self.provider=provider; self.title=title; self.project=project; self.state=state; self.updatedAt=updatedAt; self.activity=activity; self.parentId=parentId
    }
}
public struct HostInfo: Codable, Equatable, Sendable { public var id: String; public var name: String; public var platform: String }
public struct SystemReading: Codable, Equatable, Sendable {
    public var cpuPercent: Double?; public var memoryUsedBytes: UInt64?; public var memoryTotalBytes: UInt64?; public var diskFreeBytes: UInt64?; public var diskTotalBytes: UInt64?
    public init(cpuPercent: Double? = nil, memoryUsedBytes: UInt64? = nil, memoryTotalBytes: UInt64? = nil, diskFreeBytes: UInt64? = nil, diskTotalBytes: UInt64? = nil) {
        self.cpuPercent=cpuPercent; self.memoryUsedBytes=memoryUsedBytes; self.memoryTotalBytes=memoryTotalBytes; self.diskFreeBytes=diskFreeBytes; self.diskTotalBytes=diskTotalBytes
    }
}
public struct Snapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int; public var host: HostInfo; public var generatedAt: Date; public var sessions: [AgentSession]; public var system: SystemReading; public var errors: [String]?
    public static func decode(_ data: Data) throws -> Snapshot {
        guard data.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = format.date(from: value) { return date }
            format.formatOptions = [.withInternetDateTime]
            if let date = format.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp")
        }
        let value = try decoder.decode(Snapshot.self, from: data)
        guard value.schemaVersion == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
        return value
    }
}
public struct SessionRow: Identifiable, Equatable, Sendable {
    public var hostID: String; public var hostName: String; public var session: AgentSession; public var connected: Bool
    public var id: String { [hostID, session.provider, session.id].map { "\($0.utf8.count):\($0)" }.joined() }
    public init(hostID: String, hostName: String, session: AgentSession, connected: Bool = true) { self.hostID=hostID; self.hostName=hostName; self.session=session; self.connected=connected }
}
public struct AgentPresentation {
    public var visible: [SessionRow]; public var hiddenCount: Int; public var attentionCount: Int; public var workingCount: Int
    public var hiddenAttentionCount: Int {
        attentionCount-visible.filter { $0.connected && $0.session.state == .needsAttention }.count
    }
    public var overflowLabel: String? {
        if hiddenAttentionCount > 0 { return "+\(hiddenCount) more · \(hiddenAttentionCount) \(hiddenAttentionCount == 1 ? "needs" : "need") you" }
        return hiddenCount > 0 ? "+\(hiddenCount) more \(hiddenCount == 1 ? "session" : "sessions")" : nil
    }
    public static func make(rows: [SessionRow], capacity: Int, showFinished: Bool = false) -> AgentPresentation {
        let filtered = rows.filter { showFinished || ($0.session.state != .finished && $0.session.state != .idle) }
        let sorted = filtered.sorted {
            let first = $0.connected ? $0.session.state.priority : AgentState.unknown.priority
            let second = $1.connected ? $1.session.state.priority : AgentState.unknown.priority
            if first != second { return first < second }
            if $0.session.updatedAt != $1.session.updatedAt { return $0.session.updatedAt > $1.session.updatedAt }
            return $0.id < $1.id
        }
        let visible = Array(sorted.prefix(max(0, capacity)))
        return AgentPresentation(visible: visible, hiddenCount: sorted.count-visible.count,
                                 attentionCount: filtered.filter { $0.connected && $0.session.state == .needsAttention }.count,
                                 workingCount: filtered.filter { $0.connected && $0.session.state == .working }.count)
    }
}

public extension AgentState {
    var priority: Int { switch self { case .needsAttention: return 0; case .working: return 1; case .unknown: return 2; case .idle: return 3; case .finished: return 4 } }
    var label: String { switch self { case .needsAttention: return "Needs you"; case .working: return "Working"; case .unknown: return "Unknown"; case .idle: return "Idle"; case .finished: return "Done" } }
}
