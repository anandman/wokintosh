import Foundation

/// Widget links carry identities only. External URLs must come from the validated
/// cache, never a query parameter in an incoming URL.
public struct PhoneRoute:Equatable,Sendable {
    public let publisherID:UUID
    public let widgetID:UUID
    public let rowID:String
    public init(publisherID:UUID,widgetID:UUID,rowID:String) {
        self.publisherID=publisherID;self.widgetID=widgetID;self.rowID=rowID
    }
    public var url:URL {
        var c=URLComponents();c.scheme="wokintosh";c.host="session"
        c.queryItems=[URLQueryItem(name:"publisher",value:publisherID.uuidString),URLQueryItem(name:"widget",value:widgetID.uuidString),URLQueryItem(name:"row",value:rowID)]
        return c.url!
    }
    public init?(url:URL) {
        guard url.absoluteString.utf8.count<=8192,let c=URLComponents(url:url,resolvingAgainstBaseURL:false),
              c.scheme=="wokintosh",c.host=="session",c.path.isEmpty,c.user==nil,c.password==nil,c.port==nil,c.fragment==nil,
              let q=c.queryItems,q.count==3,Set(q.map(\.name))==Set(["publisher","widget","row"]),
              let a=q.first(where:{$0.name=="publisher"})?.value,let publisher=UUID(uuidString:a),
              let b=q.first(where:{$0.name=="widget"})?.value,let widget=UUID(uuidString:b),
              let row=q.first(where:{$0.name=="row"})?.value,!row.isEmpty,row.utf8.count<=4096,
              row.rangeOfCharacter(from:.controlCharacters)==nil else {return nil}
        self.init(publisherID:publisher,widgetID:widget,rowID:row)
    }
    public func resolve(in feed:PublishedWidgetFeed)->PublishedAgentRow? {
        guard feed.publisherID==publisherID else {return nil}
        return feed.widgets.first(where:{$0.id==widgetID})?.agents?.rows.first(where:{$0.id==rowID})
    }
}
