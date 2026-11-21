import Foundation
import WidgetKit
import WokintoshCore

struct AgentWidgetEntry:TimelineEntry {
    var date:Date
    let publisherID:UUID?
    let widget:PublishedWidget?
    let connection:PhoneConnectionState
    let paired:Bool
    var sample=false
    static func scopedID(publisher:UUID,widget:UUID)->String {publisher.uuidString+"/"+widget.uuidString}
    var actionMessage:String?=nil
    static func make(snapshot:PhoneSnapshot,selection:String?,at now:Date,sample:Bool=false)->AgentWidgetEntry {
        let feed=snapshot.feed
        let widget:PublishedWidget?
        if let selection,let feed {
            widget=feed.widgets.first{scopedID(publisher:feed.publisherID,widget:$0.id)==selection}
        } else {widget=feed?.widgets.first}
        return AgentWidgetEntry(date:now,publisherID:feed?.publisherID,widget:widget,connection:snapshot.state,paired:snapshot.paired,sample:sample,actionMessage:snapshot.actionMessage)
    }
    static func example(at now:Date=Date())->AgentWidgetEntry {
        make(snapshot:PhoneSnapshot(feed:PhoneFixtures.feed(at:now,includeControls:true),state:.current,lastFetchedAt:now,paired:true),selection:nil,at:now,sample:true)
    }
}

/// Keep family interpretation identical for rendering and future stale entries.
enum AgentWidgetLayout {
    static func size(for family:WidgetFamily)->PhoneWidgetSize {
        if family == .systemExtraLarge {return .extraLarge}
        if #available(iOS 27.0,*),family == .systemExtraLargePortrait {return .extraLargePortrait}
        return family == .systemLarge ? .large : .medium
    }
    static var supportedFamilies:[WidgetFamily] {
        var families:[WidgetFamily]=[.systemMedium,.systemLarge,.systemExtraLarge]
        if #available(iOS 27.0,*) {families.append(.systemExtraLargePortrait)}
        return families
    }
}
