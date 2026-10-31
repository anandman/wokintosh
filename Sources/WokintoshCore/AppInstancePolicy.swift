import Foundation

public struct RunningAppInstance: Equatable, Sendable {
    public let pid:Int32
    public let bundleID:String?
    public let path:String?
    public let launchedAt:Date?
    public init(pid:Int32,bundleID:String?,path:String?=nil,launchedAt:Date?=nil) {
        self.pid=pid;self.bundleID=bundleID;self.path=path;self.launchedAt=launchedAt
    }
}
public enum AppInstancePolicy {
    public static func otherCopies(currentPID:Int32,bundleID:String?,running:[RunningAppInstance])->[RunningAppInstance] {
        guard let bundleID,!bundleID.isEmpty else {return []}
        return running.filter {$0.pid != currentPID && $0.bundleID == bundleID}.sorted {
            let first=$0.launchedAt ?? .distantPast,second=$1.launchedAt ?? .distantPast
            return first == second ? $0.pid<$1.pid:first<second
        }
    }
}
