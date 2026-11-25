import Foundation

public enum AgentControlAction:String,Codable,CaseIterable,Sendable {
    case reviewDone,reviewAllDone,reviewEarlierDone,markBlocked,clearManualBlocked,setBackgroundTaskRole
    public var title:String {
        switch self {
        case .reviewDone:return "Review Done"
        case .reviewAllDone:return "Review all Done"
        case .reviewEarlierDone:return "Review earlier Done"
        case .markBlocked:return "Mark Blocked"
        case .clearManualBlocked:return "Clear Manual Blocked"
        case .setBackgroundTaskRole:return "Change background task role"
        }
    }
}
/// Kept outside legacy `allowed` arrays so older mobile apps still decode feeds.
public struct PublishedBackgroundControls:Codable,Equatable,Sendable {
    public let revision:String
    public let taskIDs:[String]
    public init(revision:String,taskIDs:[String]) {self.revision=revision;self.taskIDs=taskIDs}
    public var isValid:Bool {
        PublishedAgentControls(revision:revision,allowed:[]).isValid && taskIDs.count<=64 && Set(taskIDs).count==taskIDs.count &&
        taskIDs.allSatisfy{!$0.isEmpty && $0.utf8.count<=180 && $0.range(of:"^[A-Za-z0-9_.:-]+$",options:.regularExpression) != nil}
    }
}
public struct PublishedAgentControls:Codable,Equatable,Sendable {
    public let revision:String
    public let allowed:[AgentControlAction]
    public init(revision:String,allowed:[AgentControlAction]) {self.revision=revision;self.allowed=allowed}
    public var isValid:Bool {revision.count==64 && revision.allSatisfy{$0.isHexDigit} && allowed.count<=5 && Set(allowed).count==allowed.count}
}
public struct AgentControlCommand:Codable,Equatable,Sendable {
    public var version=1
    public var id=UUID()
    public var issuedAt=Date()
    public let publisherID:UUID
    public let widgetID:UUID
    public let rowID:String?
    public let action:AgentControlAction
    public let revision:String
    public var taskID:String?
    public var taskRole:BackgroundTaskRole?
    public init(publisherID:UUID,widgetID:UUID,rowID:String?,action:AgentControlAction,revision:String,taskID:String?=nil,taskRole:BackgroundTaskRole?=nil) {
        self.publisherID=publisherID;self.widgetID=widgetID;self.rowID=rowID;self.action=action;self.revision=revision
        self.taskID=taskID;self.taskRole=taskRole
    }
    public var isValid:Bool {
        version==1 && PublishedAgentControls(revision:revision,allowed:[action]).isValid &&
        (action == .setBackgroundTaskRole ? (taskID.map{!$0.isEmpty && $0.utf8.count<=180 && $0.range(of:"^[A-Za-z0-9_.:-]+$",options:.regularExpression) != nil} == true && taskRole != nil) : (taskID==nil && taskRole==nil)) &&
        ([.reviewAllDone,.reviewEarlierDone].contains(action) ? rowID==nil : rowID.map{!$0.isEmpty && $0.utf8.count<=4096 && $0.rangeOfCharacter(from:.controlCharacters)==nil} == true)
    }
    public func encoded()throws->Data {
        guard isValid else {throw AgentControlError.invalid}
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting = .sortedKeys
        let data=try encoder.encode(self);guard data.count<=16384 else {throw AgentControlError.invalid};return data
    }
    public static func decode(_ data:Data)throws->Self {
        guard data.count<=16384 else {throw AgentControlError.invalid}
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let value=try decoder.decode(Self.self,from:data);guard value.isValid else {throw AgentControlError.invalid};return value
    }
}
public enum AgentControlError:Error,Equatable,LocalizedError {
    case invalid,disabled,conflict,unconfirmed,busy
    public var errorDescription:String? {
        switch self {
        case .invalid:return "This Agent action could not be read."
        case .disabled:return "Agent controls are unavailable. Enable Allow Agent controls on your publishing Mac."
        case .conflict:return "This session has changed. Refresh the list and try again."
        case .unconfirmed:return "The action was not confirmed. It may have been saved on your Mac. Refresh to check before retrying."
        case .busy:return "Another Agent action is in progress. Try again shortly."
        }
    }
}
