import Foundation

/// Optional protocol-v1 metadata. Unknown or malformed metadata never rejects a feed.
public struct CollectorInfo: Codable, Equatable, Sendable {
    public var version: String
    public var revision: String
    public var observerStatus: String?
    public init(version:String,revision:String,observerStatus:String?=nil) {
        self.version=version;self.revision=revision;self.observerStatus=observerStatus
    }
    var versionParts:[Int]? {
        let parts=version.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count==3,parts.allSatisfy({!$0.isEmpty && $0.allSatisfy(\.isNumber)}),version.count<40 else{return nil}
        let numbers=parts.compactMap{Int($0)}
        return numbers.count==3 ? numbers : nil
    }
    public var isValid:Bool {
        versionParts != nil && revision.utf8.count==64 && revision.utf8.allSatisfy{(48...57).contains($0) || (97...102).contains($0)}
    }
}

public enum CollectorUpdate: Equatable, Sendable {
    case current, updateAvailable, versionUnknown, newer, observerUpdateAvailable, observerUnavailable
    public var needsUpdate:Bool {self == .updateAvailable || self == .versionUnknown || self == .observerUpdateAvailable}
    public static func status(reported:CollectorInfo?,bundled:CollectorInfo)->CollectorUpdate {
        guard bundled.isValid,let reported,reported.isValid else{return .versionUnknown}
        if let installed=reported.versionParts,let available=bundled.versionParts,
           available.lexicographicallyPrecedes(installed) {return .newer}
        if reported.revision != bundled.revision {return .updateAvailable}
        if reported.observerStatus == "updateAvailable" {return .observerUpdateAvailable}
        if reported.observerStatus == "unavailable" {return .observerUnavailable}
        return .current
    }
    public var message:String {
        switch self {
        case .current:return "Collector is up to date"
        case .updateAvailable:return "Collector update available"
        case .versionUnknown:return "Collector version unknown — update to enable checks"
        case .newer:return "Collector is newer than this app"
        case .observerUpdateAvailable:return "Status observer update available"
        case .observerUnavailable:return "Status observer could not be checked — review it on this machine"
        }
    }
}
