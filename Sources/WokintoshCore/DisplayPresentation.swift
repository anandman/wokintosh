import Foundation

public struct FeedStatus {
    public init(name: String, snapshot: Snapshot? = nil, error: String? = nil, refreshedAt: Date? = nil) {
        self.name=name; self.snapshot=snapshot; self.error=error; self.refreshedAt=refreshedAt
    }
    public var name: String
    public var snapshot: Snapshot?
    public var error: String?
    public var refreshedAt: Date?
    public var connected: Bool { snapshot != nil && error == nil }
    public var displayName: String { name == "This Mac" ? (snapshot?.host.name ?? name) : name }
}

public enum SystemPresentation {
    public static func resolve(hostID: String?, feeds: [String: FeedStatus]) -> (String, SystemReading, Bool) {
        let feed: FeedStatus?
        if let hostID {
            feed = feeds.values.first { $0.snapshot?.host.id == hostID }
        } else {
            feed = feeds["local"]
        }
        return (feed?.displayName ?? (hostID == nil ? "This Mac" : "Selected machine"), feed?.snapshot?.system ?? SystemReading(), feed?.connected ?? false)
    }
}
