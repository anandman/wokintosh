import Foundation

/// A local user annotation, independent from a provider's runtime or goal status.
public struct BlockedSessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var hostID: String
    public var hostName: String
    public var session: AgentSession
    public var id: String { row.id }
    public var row: SessionRow { SessionRow(hostID:hostID,hostName:hostName,session:session,connected:false) }
    public init(_ row: SessionRow, activity: String = "Manually marked blocked") {
        hostID=row.hostID;hostName=row.hostName;session=row.session
        session.state = .blocked;session.activity=activity
    }
}

public struct BlockedSessionTracker: Codable, Equatable, Sendable {
    public private(set) var records: [BlockedSessionRecord] = []
    public init() {}
    private enum CodingKeys: String,CodingKey { case records }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        records=Array((try c.decodeIfPresent([BlockedSessionRecord].self,forKey:.records) ?? []).suffix(512))
    }
    public func contains(_ id: String) -> Bool { records.contains { $0.id == id } }
    public mutating func mark(_ row: SessionRow) {
        let record=BlockedSessionRecord(row)
        if let index=records.firstIndex(where:{$0.id == row.id}) { records[index]=record }
        else { records.append(record);records=Array(records.suffix(512)) }
    }
    public mutating func clear(_ id: String) { records.removeAll { $0.id == id } }
    public func applying(to rows: [SessionRow], connectedHostIDs: Set<String>) -> [SessionRow] {
        var result=Dictionary(rows.map { ($0.id,$0) },uniquingKeysWith:{first,_ in first})
        for record in records {
            var row=result[record.id] ?? record.row
            if result[record.id] == nil { row.connected=connectedHostIDs.contains(record.hostID) }
            if !(row.connected && row.session.state == .needsAttention) { row.session.state = .blocked;row.session.activity="Manually marked blocked" }
            row.completionPending=false
            result[row.id]=row
        }
        return Array(result.values)
    }
}

/// Small last-known goal records only; a successful connected inventory resolves them.
public struct ReportedBlockedSessionTracker: Codable, Equatable, Sendable {
    public private(set) var records: [BlockedSessionRecord] = []
    public init() {}
    private enum CodingKeys: String,CodingKey { case records }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        records=Array((try c.decodeIfPresent([BlockedSessionRecord].self,forKey:.records) ?? []).suffix(512))
    }
    public func contains(_ id: String) -> Bool { records.contains { $0.id == id } }
    public mutating func ingest(_ rows:[SessionRow],connectedHostIDs:Set<String>) {
        let connected=Dictionary(rows.filter(\.connected).map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        records.removeAll { record in
            guard let row=connected[record.id] else { return connectedHostIDs.contains(record.hostID) }
            if row.session.goalBlocked == false { return true }
            return false // A runtime state without goal knowledge cannot resolve a goal.
        }
        for row in connected.values where row.session.goalBlocked != false && (row.session.goalBlocked == true || row.session.state == .blocked) {
            var record=BlockedSessionRecord(row,activity:"Goal blocked (last reported)")
            record.session.goalBlocked=true
            if let index=records.firstIndex(where:{$0.id == row.id}) { records[index]=record }
            else { records.append(record) }
        }
        records=Array(records.suffix(512))
    }
    public func applying(to rows:[SessionRow],connectedHostIDs:Set<String>) -> [SessionRow] {
        var result=Dictionary(rows.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        for record in records {
            var row=result[record.id] ?? record.row
            if result[record.id] == nil {
                if connectedHostIDs.contains(record.hostID) { continue }
            } else if row.connected {
                if row.session.goalBlocked == false { continue }
            }
            if !(row.connected && row.session.state == .needsAttention) {
                row.session.state = .blocked;row.session.activity="Goal blocked (last reported)"
            }
            row.session.goalBlocked=true;row.completionPending=false
            result[row.id]=row
        }
        return Array(result.values)
    }
}
