import Foundation

public enum PhoneWidgetSize:Sendable {case medium,large}

public struct PhoneWidgetPresentation:Sendable {
    public let rows:[PublishedAgentRow]
    public let hiddenCount:Int
    public let earlierDoneCount:Int
    public let attentionCount:Int
    public let asOf:Date?
    public let stale:Bool
    public let offline:Bool
    public let staleTransition:Date?
    public init(agents:PublishedAgents,size:PhoneWidgetSize,accessibility:Bool,connection:PhoneConnectionState,at now:Date) {
        let capacity=size == .large ? (accessibility ? 3 : 5) : (accessibility ? 1 : 2)
        rows=Array(agents.rows.prefix(capacity));hiddenCount=max(0,agents.totalCount-rows.count)
        earlierDoneCount=agents.earlierDoneCount;attentionCount=agents.attentionCount
        asOf=rows.isEmpty ? agents.sourceObservedAt : (rows.allSatisfy{$0.sourceObservedAt != nil} ? rows.compactMap(\.sourceObservedAt).min() : nil)
        offline=connection == .offline || (agents.offlineSourceCount ?? 0)>0 || rows.contains{!$0.connected}
        if let asOf {stale=now.timeIntervalSince(asOf)>1800 || asOf.timeIntervalSince(now)>60} else {stale=true}
        if !stale,!offline,let asOf {staleTransition=asOf.addingTimeInterval(1801)} else {staleTransition=nil}
    }
}
