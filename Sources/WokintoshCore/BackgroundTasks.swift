import Foundation

public enum BackgroundTaskRole:String,Codable,CaseIterable,Identifiable,Sendable {
    case automatic,work,monitor
    public var id:String {rawValue}
    public var title:String {switch self {case .automatic:return "Automatic";case .work:return "Work";case .monitor:return "Monitor"}}
}
public enum BackgroundTaskStatus:String,Codable,Sendable {
    case running,completed,failed,cancelled,ended,unknown,needsAttention
    public var isActive:Bool {self == .running || self == .unknown || self == .needsAttention}
    public var label:String {switch self {case .running:return "Running";case .completed:return "Completed";case .failed:return "Failed";case .cancelled:return "Cancelled";case .ended:return "Ended";case .unknown:return "Unverified";case .needsAttention:return "Needs you"}}
}
public struct BackgroundTask:Codable,Equatable,Identifiable,Sendable {
    public var id:String
    public var kind:String
    public var label:String
    public var status:BackgroundTaskStatus
    public var startedAt:Date
    public var updatedAt:Date
    public var observedAt:Date
    public var role:BackgroundTaskRole?
    public init(id:String,kind:String,label:String,status:BackgroundTaskStatus,startedAt:Date,updatedAt:Date,observedAt:Date,role:BackgroundTaskRole?=nil) {
        self.id=id;self.kind=kind;self.label=label;self.status=status;self.startedAt=startedAt;self.updatedAt=updatedAt;self.observedAt=observedAt;self.role=role
    }
    public var effectiveRole:BackgroundTaskRole {role == nil || role == .automatic ? (kind == "monitor" ? .monitor : .work) : role!}
    public var isValid:Bool {
        !id.isEmpty && id.utf8.count<=180 && id.range(of:"^[A-Za-z0-9_.:-]+$",options:.regularExpression) != nil &&
        ["shell","monitor","subagent","other"].contains(kind) && label.count<=90 && label.rangeOfCharacter(from:.controlCharacters)==nil &&
        [startedAt,updatedAt,observedAt].allSatisfy{$0.timeIntervalSince1970.isFinite}
    }
    public func isVerified(at now:Date)->Bool {status != .unknown && (-60...1800).contains(now.timeIntervalSince(observedAt))}
}
public struct BackgroundTaskEvidence:Codable,Equatable,Sendable {
    public var version=1
    public var foregroundState:AgentState
    public var foregroundUpdatedAt:Date
    public var tasks:[BackgroundTask]
    public var incomplete:Bool?
    public init(foregroundState:AgentState,foregroundUpdatedAt:Date,tasks:[BackgroundTask],incomplete:Bool=false) {
        self.foregroundState=foregroundState;self.foregroundUpdatedAt=foregroundUpdatedAt;self.tasks=tasks;self.incomplete=incomplete
    }
    public var isValid:Bool {version==1 && tasks.count<=64 && tasks.allSatisfy(\.isValid) && Set(tasks.map(\.id)).count==tasks.count && foregroundUpdatedAt.timeIntervalSince1970.isFinite}
    public var activeTasks:[BackgroundTask] {tasks.filter{$0.status.isActive}}
    public var completionAt:Date {tasks.filter{$0.effectiveRole == .work}.map(\.updatedAt).reduce(foregroundUpdatedAt,max)}
}

public extension AgentSession {
    var isMonitoring:Bool {
        guard state == .idle,let background,background.incomplete != true,!background.activeTasks.isEmpty else {return false}
        return background.activeTasks.allSatisfy{$0.effectiveRole == .monitor}
    }
    var statusLabel:String {isMonitoring ? "Monitoring" : state.label}
    func resolvingBackground(at now:Date)->AgentSession {
        guard let background,background.isValid else {return self}
        var value=self
        if state == .blocked || goalBlocked == true || background.foregroundState == .blocked {value.state = .blocked;return value}
        if state == .needsAttention || background.foregroundState == .needsAttention || background.activeTasks.contains(where:{$0.status == .needsAttention}) {value.state = .needsAttention;return value}
        let active=background.activeTasks
        if background.foregroundState == .working && (-60...1800).contains(now.timeIntervalSince(background.foregroundUpdatedAt)) {
            value.state = .working;value.activity="Working"
        } else if active.contains(where:{$0.effectiveRole == .work && $0.isVerified(at:now)}) {
            value.state = .working;let count=active.filter{$0.effectiveRole == .work && $0.isVerified(at:now)}.count
            value.activity="\(count) background \(count == 1 ? "task" : "tasks") running"
        } else if background.incomplete == true || active.contains(where:{!$0.isVerified(at:now)}) {
            value.state = .unknown;value.activity="Background task activity unverified"
        } else if !active.isEmpty {
            value.state = .idle;value.activity="Monitoring"
        } else {
            value.state=background.foregroundState
            if value.state == .working {value.state = .unknown;value.activity="No recent lifecycle signal"}
        }
        value.updatedAt=background.completionAt
        return value
    }
    /// A pending foreground completion is distinct from ongoing monitoring. Monitor
    /// heartbeats/end events never change this receipt's lifecycle timestamp.
    var backgroundCompletionCandidate:AgentSession {
        guard isMonitoring,let background,background.foregroundState == .finished else {return self}
        var value=self;value.state = .finished;value.updatedAt=background.completionAt;return value
    }
}

/// Mac-local bookkeeping, deliberately separate from portable dashboard layouts.
public struct BackgroundTaskRoleStore:Codable,Equatable,Sendable {
    private struct Choice:Codable,Equatable,Sendable {
        let rowID:String;let taskID:String;let startedAt:Date;let role:BackgroundTaskRole
    }
    private var choices:[Choice]=[]
    public init() {}
    private enum CodingKeys:String,CodingKey {case choices}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        choices=try c.decode([Choice].self,forKey:.choices)
        guard choices.count<=1024,choices.allSatisfy({!$0.rowID.isEmpty && $0.rowID.utf8.count<=4096 && !$0.taskID.isEmpty && $0.taskID.utf8.count<=180}) else {throw WidgetFeedError.invalid}
    }
    public func role(for task:BackgroundTask,rowID:String)->BackgroundTaskRole {
        choices.last(where:{$0.rowID==rowID && $0.taskID==task.id && $0.startedAt==task.startedAt})?.role ?? .automatic
    }
    public mutating func set(_ role:BackgroundTaskRole,for task:BackgroundTask,rowID:String) {
        choices.removeAll{$0.rowID==rowID && $0.taskID==task.id}
        if role != .automatic {choices.append(Choice(rowID:rowID,taskID:task.id,startedAt:task.startedAt,role:role))}
        choices=Array(choices.suffix(1024))
    }
    public func applying(to row:SessionRow,at now:Date)->SessionRow {
        var result=row
        if var evidence=result.session.background {
            for i in evidence.tasks.indices {evidence.tasks[i].role=role(for:evidence.tasks[i],rowID:row.id)}
            result.session.background=evidence
        }
        result.session=result.session.resolvingBackground(at:now)
        return result
    }
}
