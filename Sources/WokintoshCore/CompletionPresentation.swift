import Foundation

public enum DoneCollapseInterval:String,Codable,CaseIterable,Identifiable,Sendable {
    case untilReviewed,minutes15,hour1,hours4,day1
    public var id:String {rawValue}
    public var title:String {
        switch self {case .untilReviewed:return "Until reviewed";case .minutes15:return "15 minutes";case .hour1:return "1 hour";case .hours4:return "4 hours";case .day1:return "1 day"}
    }
    public var seconds:TimeInterval? {
        switch self {case .untilReviewed:return nil;case .minutes15:return 900;case .hour1:return 3600;case .hours4:return 14400;case .day1:return 86400}
    }
}

/// A presentation-only partition: moving a row never acknowledges its completion.
public struct CompletionPresentation {
    public var main:[SessionRow]
    public var earlier:[SessionRow]
    public static func make(rows:[SessionRow],interval:DoneCollapseInterval,at now:Date)->CompletionPresentation {
        guard let seconds=interval.seconds else {return CompletionPresentation(main:rows,earlier:[])}
        var main:[SessionRow]=[],earlier:[SessionRow]=[]
        for row in rows {
            if row.completionPending,row.session.state == .finished,row.session.goalBlocked != true,
               let observed=row.completionObservedAt,now.timeIntervalSince(observed)>=seconds {
                earlier.append(row)
            } else {main.append(row)}
        }
        earlier.sort {
            if $0.session.updatedAt != $1.session.updatedAt {return $0.session.updatedAt>$1.session.updatedAt}
            return $0.id<$1.id
        }
        return CompletionPresentation(main:main,earlier:earlier)
    }
    public func page(capacity:Int,showFinished:Bool)->AgentPresentation {
        var page=AgentPresentation.make(rows:main,capacity:capacity,showFinished:showFinished)
        page.doneCount+=earlier.count
        return page
    }
}
