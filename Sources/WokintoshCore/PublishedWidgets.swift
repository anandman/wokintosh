import Foundation

public enum WidgetFeedError:Error,LocalizedError {
    case oversized,unsupported,invalid
    public var errorDescription:String? {
        switch self {
        case .oversized:return "The published widget data is too large."
        case .unsupported:return "This widget feed needs a newer version of Wokintosh."
        case .invalid:return "The published widget data could not be read."
        }
    }
}

public enum SourceFreshness:String,Sendable {case current,stale,offline}

public struct PublishedAgentRow:Codable,Equatable,Identifiable,Sendable {
    public let hostID:String
    public let hostName:String
    public let session:AgentSession
    public let connected:Bool
    public let completionPending:Bool
    public let sourceObservedAt:Date?
    public var id:String {SessionRow(hostID:hostID,hostName:hostName,session:session).id}
    public init(row:SessionRow,observedAt:Date?) {
        hostID=row.hostID;hostName=String(row.hostName.prefix(180))
        let source=row.session
        session=AgentSession(id:source.id,provider:source.provider,title:String(source.title.prefix(180)),
                             project:String((source.project as NSString).lastPathComponent.prefix(180)),state:source.state,
                             updatedAt:source.updatedAt,isHelper:source.isHelper,goalBlocked:source.goalBlocked,openURLs:source.openURLs)
        connected=row.connected;completionPending=row.completionPending;sourceObservedAt=observedAt
    }
    public func freshness(at now:Date)->SourceFreshness {
        guard connected else {return .offline}
        guard let sourceObservedAt,now.timeIntervalSince(sourceObservedAt)<=1800,
              sourceObservedAt.timeIntervalSince(now)<=60 else {return .stale}
        return .current
    }
    public var isValid:Bool {
        !hostID.isEmpty && !session.id.isEmpty &&
        [hostID,hostName,session.id,session.provider,session.title,session.project].allSatisfy{$0.utf8.count<=720 && $0.rangeOfCharacter(from:.controlCharacters)==nil} &&
        !session.project.contains("/") && session.activity==nil
    }
}

public struct PublishedAgents:Codable,Equatable,Sendable {
    public var rows:[PublishedAgentRow]
    public let totalCount:Int
    public let earlierDoneCount:Int
    public let attentionCount:Int
    public let workingCount:Int
    public let doneCount:Int
    public let sourceObservedAt:Date?
    public var offlineSourceCount:Int?=nil
    public var hiddenCount:Int {max(0,totalCount-rows.count)}
    public var asOf:Date? {
        guard !rows.isEmpty else {return sourceObservedAt}
        guard rows.allSatisfy({$0.sourceObservedAt != nil}) else {return nil}
        return rows.compactMap(\.sourceObservedAt).min()
    }
    public static func make(rows:[SessionRow],sourceObservations:[String:Date],interval:DoneCollapseInterval,showFinished:Bool,offlineSourceCount:Int=0,at now:Date)->PublishedAgents {
        let completion=CompletionPresentation.make(rows:rows,interval:interval,at:now)
        let page=completion.page(capacity:128,showFinished:showFinished)
        return PublishedAgents(rows:page.visible.map{PublishedAgentRow(row:$0,observedAt:sourceObservations[$0.hostID])},
                               totalCount:page.visible.count+page.hiddenCount,earlierDoneCount:completion.earlier.count,
                               attentionCount:page.attentionCount,workingCount:page.workingCount,doneCount:page.doneCount,
                               sourceObservedAt:sourceObservations.values.min(),offlineSourceCount:max(0,offlineSourceCount))
    }
    public var isValid:Bool {
        let counts=[totalCount,earlierDoneCount,attentionCount,workingCount,doneCount]
        return (offlineSourceCount ?? 0)>=0 && (offlineSourceCount ?? 0)<=10000 && rows.count<=128 && rows.allSatisfy(\.isValid) && Set(rows.map(\.id)).count==rows.count &&
        counts.allSatisfy{$0>=0 && $0<=1_000_000} && totalCount>=rows.count && attentionCount<=totalCount && workingCount<=totalCount
    }
}

/// Each widget payload can evolve independently. Initial clients understand Agents v1.
public struct PublishedWidget:Codable,Equatable,Identifiable,Sendable {
    public let id:UUID
    public let kind:String
    public let payloadVersion:Int
    public let name:String
    public var agents:PublishedAgents?
    public init(id:UUID,name:String,agents:PublishedAgents) {
        self.id=id;kind="agents";payloadVersion=1;self.name=String(name.prefix(180));self.agents=agents
    }
    private enum CodingKeys:String,CodingKey {case id,kind,payloadVersion,name,payload}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(UUID.self,forKey:.id);kind=try c.decode(String.self,forKey:.kind)
        payloadVersion=try c.decode(Int.self,forKey:.payloadVersion);name=try c.decode(String.self,forKey:.name)
        guard name.utf8.count<=720 else {throw WidgetFeedError.invalid}
        if kind=="agents" && payloadVersion==1,let value=try? c.decode(PublishedAgents.self,forKey:.payload),value.isValid {agents=value}
    }
    public func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(id,forKey:.id);try c.encode(kind,forKey:.kind);try c.encode(payloadVersion,forKey:.payloadVersion)
        try c.encode(name,forKey:.name);try c.encodeIfPresent(agents,forKey:.payload)
    }
}

public struct PublishedWidgetFeed:Codable,Equatable,Sendable {
    public static let maximumBytes=1024*1024
    public let format:String
    public let version:Int
    public let publisherID:UUID
    public let publisherName:String
    public let publishedAt:Date
    public var widgets:[PublishedWidget]
    public init(publisherID:UUID,publisherName:String,publishedAt:Date,widgets:[PublishedWidget]) {
        format="dev.wokintosh.widgets";version=1;self.publisherID=publisherID
        self.publisherName=String(publisherName.prefix(180));self.publishedAt=publishedAt;self.widgets=widgets
    }
    private enum CodingKeys:String,CodingKey {case format,version,publisherID,publisherName,publishedAt,widgets}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        format=try c.decode(String.self,forKey:.format);version=try c.decode(Int.self,forKey:.version)
        guard format=="dev.wokintosh.widgets",version==1 else {throw WidgetFeedError.unsupported}
        publisherID=try c.decode(UUID.self,forKey:.publisherID);publisherName=try c.decode(String.self,forKey:.publisherName)
        guard publisherName.utf8.count<=720 else {throw WidgetFeedError.invalid}
        publishedAt=try c.decode(Date.self,forKey:.publishedAt)
        var entries=try c.nestedUnkeyedContainer(forKey:.widgets)
        widgets=[];var seen=Set<UUID>()
        while !entries.isAtEnd {
            let item=try entries.superDecoder()
            if let widget=try? PublishedWidget(from:item),widget.agents != nil,seen.insert(widget.id).inserted {widgets.append(widget)}
            guard widgets.count<=128 else {throw WidgetFeedError.oversized}
        }
    }
    public static func decode(_ data:Data)throws->PublishedWidgetFeed {
        guard data.count<=maximumBytes else {throw WidgetFeedError.oversized}
        let decoder=JSONDecoder()
        decoder.dateDecodingStrategy = .custom {decoder in
            let text=try decoder.singleValueContainer().decode(String.self)
            let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            if let date=formatter.date(from:text) {return date}
            formatter.formatOptions=[.withInternetDateTime]
            guard let date=formatter.date(from:text) else {throw WidgetFeedError.invalid}
            return date
        }
        return try decoder.decode(Self.self,from:data)
    }
    public func encoded()throws->Data {
        guard widgets.count<=128,Set(widgets.map(\.id)).count==widgets.count,
              widgets.allSatisfy({$0.agents?.isValid == true}) else {throw WidgetFeedError.invalid}
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting=[.sortedKeys]
        // Reserve envelope/payload metadata once, then spend the remaining bytes on
        // ordered row prefixes, one row per widget per round. Each candidate row is
        // measured once; the full feed is encoded only after the budget is assigned.
        var bounded=self
        for index in widgets.indices {bounded.widgets[index].agents!.rows=[]}
        let metadata=try encoder.encode(bounded)
        guard metadata.count<=Self.maximumBytes else {throw WidgetFeedError.oversized}
        var remaining=Self.maximumBytes-metadata.count
        var closed=Set<Int>()
        for offset in 0..<128 {
            for index in widgets.indices where !closed.contains(index) {
                guard let rows=widgets[index].agents?.rows,offset<rows.count else {closed.insert(index);continue}
                let cost=try encoder.encode(rows[offset]).count+(offset==0 ? 0 : 1)
                guard cost<=remaining else {closed.insert(index);continue}
                bounded.widgets[index].agents!.rows.append(rows[offset]);remaining-=cost
            }
            if closed.count==widgets.count {break}
        }
        let data=try encoder.encode(bounded)
        guard data.count<=Self.maximumBytes else {throw WidgetFeedError.oversized}
        return data
    }
}
