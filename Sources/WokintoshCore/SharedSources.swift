import Foundation

/// Machine-local consent. Never part of DashboardDocument or portable setups.
public struct SourceSharingOptions:Codable,Equatable,Sendable {
    public var shareMusic:Bool
    public var shareCalendar:Bool
    public var calendarIDs:[String]
    public init(shareMusic:Bool=false,shareCalendar:Bool=false,calendarIDs:[String]=[]) {
        self.shareMusic=shareMusic;self.shareCalendar=shareCalendar;self.calendarIDs=calendarIDs
    }
    public var enabled:Bool {shareMusic || shareCalendar}
}

private func sharedText(_ value:String)->String {
    String(value.components(separatedBy:.controlCharacters).joined(separator:" ").prefix(512))
}

public struct SharedMusic:Codable,Equatable,Sendable {
    public static let maximumArtworkBytes=128*1024
    public var available:Bool
    public var updatedAt:Date
    public var status:String
    public var title:String
    public var artist:String
    public var album:String
    public var isPlaying:Bool
    public var position:Double
    public var duration:Double
    public var artworkBase64:Data?
    public init(info:NowPlayingInfo,available:Bool,at date:Date,artwork:Data?=nil) {
        self.available=available;updatedAt=available ? info.updatedAt : date;status=sharedText(info.status)
        title=available ? sharedText(info.title) : "";artist=available ? sharedText(info.artist) : "";album=available ? sharedText(info.album) : ""
        duration=available && info.duration.isFinite ? min(604800,max(0,info.duration)) : 0
        position=available && info.position.isFinite ? min(duration,max(0,info.position)) : 0
        isPlaying=available && !title.isEmpty && info.isPlaying
        artworkBase64=available && (artwork?.count ?? 0)<=Self.maximumArtworkBytes ? artwork : nil
    }
    public var isValid:Bool {
        [status,title,artist,album].allSatisfy{$0.count<=512} && updatedAt.timeIntervalSince1970.isFinite &&
        position.isFinite && duration.isFinite && position>=0 && duration>=0 && duration<=604800 && position<=duration &&
        (artworkBase64?.count ?? 0)<=Self.maximumArtworkBytes
    }
    public var info:NowPlayingInfo {
        guard available else {return NowPlayingInfo(updatedAt:updatedAt,status:status)}
        return NowPlayingInfo(title:title,artist:artist,album:album,isPlaying:isPlaying,position:position,duration:duration,updatedAt:updatedAt,status:status,artworkData:artworkBase64)
    }
}

public struct SharedCalendar:Codable,Equatable,Sendable {
    public var available:Bool
    public var updatedAt:Date
    public var status:String
    public var calendars:[CalendarDescriptor]
    public var events:[CalendarEntry]
    public init(info:CalendarInfo,available:Bool,calendarIDs:[String],at date:Date) {
        self.available=available;updatedAt=date;status=sharedText(info.status)
        let selected=Set(calendarIDs.prefix(128))
        calendars=available ? Array(info.calendars.filter{selected.contains($0.id)}.prefix(128)).map {
            CalendarDescriptor(id:sharedText($0.id),title:sharedText($0.title),sourceTitle:sharedText($0.sourceTitle))
        } : []
        events=available ? Array(info.events.filter {
            selected.contains($0.calendarID) && $0.startDate.timeIntervalSince1970.isFinite && $0.endDate.timeIntervalSince1970.isFinite &&
            $0.endDate>$0.startDate && $0.endDate>date && $0.startDate<date.addingTimeInterval(7*86400)
        }.sorted{$0.startDate<$1.startDate}.prefix(256)).map {
            CalendarEntry(id:sharedText($0.id),title:sharedText($0.title),startDate:$0.startDate,endDate:$0.endDate,isAllDay:$0.isAllDay,
                          calendarID:sharedText($0.calendarID),calendarTitle:sharedText($0.calendarTitle))
        } : []
    }
    public var isValid:Bool {
        status.count<=512 && updatedAt.timeIntervalSince1970.isFinite && calendars.count<=128 && events.count<=256 &&
        calendars.allSatisfy{[$0.id,$0.title,$0.sourceTitle].allSatisfy{$0.count<=512}} &&
        events.allSatisfy{[$0.id,$0.title,$0.calendarID,$0.calendarTitle].allSatisfy{$0.count<=512} &&
            $0.startDate.timeIntervalSince1970.isFinite && $0.endDate.timeIntervalSince1970.isFinite && $0.endDate>$0.startDate}
    }
    public var info:CalendarInfo {
        CalendarInfo(events:available ? events : [],status:status,authorized:available,calendars:available ? calendars : [])
    }
}

public struct SharedSourcesSnapshot:Codable,Equatable,Sendable {
    public var version:Int
    public var generatedAt:Date
    public var music:SharedMusic?
    public var calendar:SharedCalendar?
    public init(version:Int=1,generatedAt:Date,music:SharedMusic?=nil,calendar:SharedCalendar?=nil) {
        self.version=version;self.generatedAt=generatedAt;self.music=music;self.calendar=calendar
    }
    public var isValid:Bool {version == 1 && generatedAt.timeIntervalSince1970.isFinite && (music?.isValid ?? true) && (calendar?.isValid ?? true)}
}

public enum RemoteSourceState:Equatable,Sendable {case ready,notShared,unavailable,stale,offline}
public struct RemoteSourceStatus:Equatable,Sendable {
    public var name:String
    public var state:RemoteSourceState
    public var updatedAt:Date?
    public init(name:String,state:RemoteSourceState,updatedAt:Date?=nil) {self.name=name;self.state=state;self.updatedAt=updatedAt}
    public var warning:String? {
        let time=updatedAt.map{$0.formatted(date:.omitted,time:.shortened)}
        switch state {
        case .ready:return nil
        case .notShared:return "Not shared"
        case .unavailable:return "Source unavailable"
        case .stale:return "Stale"+(time.map{" · updated \($0)"} ?? "")
        case .offline:return "Offline"+(time.map{" · last updated \($0)"} ?? "")
        }
    }
}
/// Shared by the content frame and Calendar title-bar capacity calculation.
public struct NativeWidgetSourceLayout:Equatable,Sendable {
    public let statusHeight:Double
    public let contentHeight:Double
    public let showsContent:Bool
    public init(height:Double,textScale:Double,source:RemoteSourceStatus?) {
        let height=max(0,height.isFinite ? height : 0),scale=max(0.8,textScale.isFinite ? textScale : 1)
        statusHeight=source?.warning == nil ? 0 : min(height,24*scale)
        contentHeight=max(0,height-statusHeight)
        showsContent=contentHeight>=26*scale
    }
}
public struct MusicSourcePresentation:Equatable,Sendable {
    public var info:NowPlayingInfo
    /// nil means local; only local sources may offer playback controls.
    public var source:RemoteSourceStatus?
    public init(info:NowPlayingInfo,source:RemoteSourceStatus?=nil) {self.info=info;self.source=source}
    public var allowsPlayback:Bool {source == nil}
}
public struct CalendarSourcePresentation:Equatable,Sendable {
    public var info:CalendarInfo
    public var source:RemoteSourceStatus?
    public var loading:Bool
    public init(info:CalendarInfo,source:RemoteSourceStatus?=nil,loading:Bool=false) {self.info=info;self.source=source;self.loading=loading}
}

public enum NativeSourcePresentation {
    public static let freshnessInterval:TimeInterval=90
    public static func music(hostID:String,feeds:[String:FeedStatus],at now:Date=Date())->MusicSourcePresentation {
        let feed=feeds.values.first{$0.snapshot?.host.id == hostID}
        let publication=feed?.snapshot?.sharedSources
        let music=publication?.music
        var status=status(feed:feed,publication:publication,present:music != nil,available:music?.available ?? false,updatedAt:music?.updatedAt,at:now)
        var info=music?.info ?? NowPlayingInfo(status:"Enable Now Playing sharing in Wokintosh on \(status.name), and update its collector to 1.3 or later.")
        if status.state != .ready {info.isPlaying=false}
        if status.state == .notShared {status.updatedAt=nil}
        return MusicSourcePresentation(info:info,source:status)
    }
    public static func calendar(hostID:String,feeds:[String:FeedStatus],at now:Date=Date())->CalendarSourcePresentation {
        let feed=feeds.values.first{$0.snapshot?.host.id == hostID}
        let publication=feed?.snapshot?.sharedSources
        let calendar=publication?.calendar
        let status=status(feed:feed,publication:publication,present:calendar != nil,available:calendar?.available ?? false,updatedAt:calendar?.updatedAt,at:now)
        let info=calendar?.info ?? CalendarInfo(status:"Enable selected calendar sharing in Wokintosh on \(status.name), and update its collector to 1.3 or later.")
        return CalendarSourcePresentation(info:info,source:status)
    }
    private static func status(feed:FeedStatus?,publication:SharedSourcesSnapshot?,present:Bool,available:Bool,updatedAt:Date?,at now:Date)->RemoteSourceStatus {
        let name=feed?.displayName ?? "Selected machine"
        let state:RemoteSourceState
        if feed?.connected != true {state = .offline}
        else if !present || publication?.isValid != true {state = .notShared}
        else if !fresh(publication?.generatedAt,at:now) || !fresh(updatedAt,at:now) {state = .stale}
        else {state = available ? .ready : .unavailable}
        return RemoteSourceStatus(name:name,state:state,updatedAt:updatedAt)
    }
    private static func fresh(_ date:Date?,at now:Date)->Bool {
        guard let date else {return false}
        return (-30...freshnessInterval).contains(now.timeIntervalSince(date))
    }
}
