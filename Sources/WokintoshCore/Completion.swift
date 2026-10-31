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
    private var baselines: [String:Date] = [:]
    private var lastSeen: [String:Date] = [:]
    public init() {}
    private enum CodingKeys: String,CodingKey { case pending,reviewed,active,baselines,lastSeen }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        pending=try c.decodeIfPresent([CompletionRecord].self,forKey:.pending) ?? []
        reviewed=try c.decodeIfPresent([String:Date].self,forKey:.reviewed) ?? [:]
        active=try c.decodeIfPresent([String:Date].self,forKey:.active) ?? [:]
        baselines=try c.decodeIfPresent([String:Date].self,forKey:.baselines) ?? [:]
        lastSeen=try c.decodeIfPresent([String:Date].self,forKey:.lastSeen) ?? [:]
    }
    public mutating func ingest(_ rows: [SessionRow], connectedHostIDs:[String] = [], at now: Date = Date()) {
        reviewed=reviewed.filter { now.timeIntervalSince($0.value)<7*86400 }
        active=active.filter { now.timeIntervalSince($0.value)<7*86400 }
        lastSeen=lastSeen.filter { now.timeIntervalSince($0.value)<7*86400 }
        let connected=rows.filter(\.connected)
        let hosts=Set(connected.map(\.hostID)).union(connectedHostIDs)
        let newHosts=Set(hosts.filter { baselines[$0] == nil })
        for host in newHosts { baselines[host]=now }
        for row in connected {
            // Corrected helper/title metadata must also update persisted notices,
            // without inventing a new completion timestamp.
            if let index=pending.firstIndex(where:{$0.id == row.id}) {
                pending[index].hostName=row.hostName
                pending[index].session.isHelper=row.session.isHelper
                pending[index].session.parentId=row.session.parentId
                pending[index].session.title=row.session.title
                pending[index].session.project=row.session.project
            }
            if row.session.state == .blocked || row.session.goalBlocked == true {
                review(row.id)
                let receipt=max(row.session.updatedAt,lastSeen[row.id] ?? .distantPast,reviewed[row.id] ?? .distantPast)
                reviewed[row.id]=receipt;lastSeen[row.id]=receipt
                active.removeValue(forKey:row.id)
                continue // A goal can remain blocked after its last completed turn.
            }
            if let seen=lastSeen[row.id],seen>row.session.updatedAt { continue }
            lastSeen[row.id]=row.session.updatedAt
            if row.session.state != .finished,
               let completion=pending.first(where:{ $0.id == row.id }),
               completion.session.updatedAt < row.session.updatedAt {
                review(row.id)
            }
            if row.session.state == .working || row.session.state == .needsAttention {
                active[row.id]=row.session.updatedAt
            } else if row.session.state == .finished {
                if newHosts.contains(row.hostID) && !pending.contains(where:{$0.id == row.id}) {
                    // First inventory is a baseline, never a new-work notification.
                    reviewed[row.id]=max(reviewed[row.id] ?? .distantPast,row.session.updatedAt)
                    active.removeValue(forKey:row.id)
                    continue
                }
                let observedTurn=active[row.id].map { $0 <= row.session.updatedAt } ?? false
                let afterBaseline=baselines[row.hostID].map { $0 < row.session.updatedAt } ?? false
                guard observedTurn || afterBaseline else { continue }
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
