import Foundation

public struct CompletionRecord: Codable, Equatable, Identifiable, Sendable {
    public var hostID: String
    public var hostName: String
    public var session: AgentSession
    public var id: String { row.id }
    public var row: SessionRow { SessionRow(hostID:hostID,hostName:hostName,session:session,completionPending:true) }
    public init(_ row: SessionRow) { hostID=row.hostID;hostName=row.hostName;session=row.session }
}

public struct CompletionTracker: Codable, Equatable, Sendable {
    public private(set) var pending: [CompletionRecord] = []
    private var reviewed: [String: Date] = [:]
    private var active: [String: Date] = [:]
    public init() {}
    public mutating func ingest(_ rows: [SessionRow], at now: Date = Date()) {
        reviewed=reviewed.filter { now.timeIntervalSince($0.value)<7*86400 }
        active=active.filter { now.timeIntervalSince($0.value)<7*86400 }
        for row in rows where row.connected {
            if row.session.state == .working || row.session.state == .needsAttention {
                active[row.id]=row.session.updatedAt
                pending.removeAll { $0.id == row.id && $0.session.updatedAt < row.session.updatedAt }
            } else if row.session.state == .finished {
                let recent=now.timeIntervalSince(row.session.updatedAt)<86400
                guard recent || active[row.id] != nil else { continue }
                guard reviewed[row.id].map({ $0 < row.session.updatedAt }) ?? true else { continue }
                if let index=pending.firstIndex(where:{ $0.id == row.id }) {
                    if pending[index].session.updatedAt < row.session.updatedAt { pending[index]=CompletionRecord(row) }
                } else { pending.append(CompletionRecord(row)) }
                active.removeValue(forKey:row.id)
            }
        }
    }
    public mutating func review(_ id: String) {
        guard let record=pending.first(where:{ $0.id == id }) else { return }
        reviewed[id]=record.session.updatedAt
        pending.removeAll { $0.id == id }
    }
}
