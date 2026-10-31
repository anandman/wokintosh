import Foundation
public enum WidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case agents, music, system, clock, weather, calendar
    public var id: String { rawValue }
    public var title: String { switch self { case .agents: return "Agents"; case .music: return "Now Playing"; case .system: return "System"; case .clock: return "Clock"; case .weather: return "Weather"; case .calendar: return "Calendar" } }
}
public struct WidgetFrame: Codable, Equatable, Sendable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x=x; self.y=y; self.width=width; self.height=height }
    static func minimumSize(for kind: WidgetKind) -> (width: Double, height: Double) {
        switch kind {
        case .agents: return (0.25, 0.20)
        case .music: return (0.18, 0.17)
        case .calendar: return (0.18, 0.13)
        case .system: return (0.18, 0.12)
        case .clock: return (0.14, 0.12)
        case .weather: return (0.13, 0.12)
        }
    }
    public func clamped(for kind: WidgetKind) -> WidgetFrame {
        let minimum = Self.minimumSize(for: kind)
        let w = min(1, max(minimum.width, width.isFinite ? width : 0.35))
        let h = min(1, max(minimum.height, height.isFinite ? height : 0.3))
        return WidgetFrame(x: min(1-w, max(0, x.isFinite ? x : 0)), y: min(1-h, max(0, y.isFinite ? y : 0)), width: w, height: h)
    }
}
public struct Widget: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID; public var kind: WidgetKind; public var frame: WidgetFrame
    public var hostID: String?; public var provider: String?; public var showFinished: Bool; public var showHelpers: Bool
    public var systemOptions=SystemWidgetOptions()
    public var calendarOptions=CalendarSelectionOptions()
    public var weatherOptions=WeatherWidgetOptions()
    public init(kind: WidgetKind, frame: WidgetFrame) { self.id=UUID(); self.kind=kind; self.frame=frame; self.showFinished=false; self.showHelpers=false }

    private enum CodingKeys: String, CodingKey { case id,kind,frame,hostID,provider,showFinished,showHelpers,systemOptions,calendarOptions,weatherOptions }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(UUID.self,forKey:.id);kind=try c.decode(WidgetKind.self,forKey:.kind);frame=try c.decode(WidgetFrame.self,forKey:.frame)
        hostID=try c.decodeIfPresent(String.self,forKey:.hostID);provider=try c.decodeIfPresent(String.self,forKey:.provider)
        showFinished=try c.decodeIfPresent(Bool.self,forKey:.showFinished) ?? false;showHelpers=try c.decodeIfPresent(Bool.self,forKey:.showHelpers) ?? false
        systemOptions=try c.decodeIfPresent(SystemWidgetOptions.self,forKey:.systemOptions) ?? SystemWidgetOptions()
        calendarOptions=try c.decodeIfPresent(CalendarSelectionOptions.self,forKey:.calendarOptions) ?? CalendarSelectionOptions()
        weatherOptions=try c.decodeIfPresent(WeatherWidgetOptions.self,forKey:.weatherOptions) ?? WeatherWidgetOptions()
    }
}
public struct RemoteHost: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID; public var name: String; public var destination: String; public var collectorPath: String; public var enabled: Bool
    public init(name: String, destination: String, collectorPath: String = "~/.local/bin/wokintosh-agent") { self.id=UUID(); self.name=name; self.destination=destination; self.collectorPath=collectorPath; self.enabled=true }
}
public struct DashboardDocument: Codable, Equatable, Sendable {
    public var version: Int = 1; public var widgets: [Widget]; public var textScale: Double = 1
    public var remoteHosts: [RemoteHost] = []; public var weatherPlace: String = ""; public var latitude: Double?; public var longitude: Double?; public var fahrenheit: Bool = false
    public var displayID: UInt32?; public var presentationEnabled: Bool = false; public var previewMode: Bool = false; public var previewWidthMM: Double = 111
    public var layoutGridRevision=1
    public var snapToGrid=true
    public var nativeFullscreen=true
    public var completions=CompletionTracker()
    public var blockedSessions=BlockedSessionTracker()
    public var reportedBlockedSessions=ReportedBlockedSessionTracker()
    public init(widgets: [Widget]) { self.widgets=widgets }
    private enum CodingKeys: String, CodingKey { case layoutGridRevision,snapToGrid,nativeFullscreen,completions,blockedSessions,reportedBlockedSessions,version, widgets, textScale, remoteHosts, weatherPlace, latitude, longitude, fahrenheit, displayID, presentationEnabled, previewMode, previewWidthMM }
    public init(from decoder: Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        version=try values.decodeIfPresent(Int.self,forKey:.version) ?? 1
        guard version == 1 else { throw DecodingError.dataCorruptedError(forKey:.version,in:values,debugDescription:"Unsupported layout version") }
        snapToGrid=try values.decodeIfPresent(Bool.self,forKey:.snapToGrid) ?? true
        nativeFullscreen=try values.decodeIfPresent(Bool.self,forKey:.nativeFullscreen) ?? true
        completions=try values.decodeIfPresent(CompletionTracker.self,forKey:.completions) ?? CompletionTracker()
        blockedSessions=try values.decodeIfPresent(BlockedSessionTracker.self,forKey:.blockedSessions) ?? BlockedSessionTracker()
        reportedBlockedSessions=try values.decodeIfPresent(ReportedBlockedSessionTracker.self,forKey:.reportedBlockedSessions) ?? ReportedBlockedSessionTracker()
        widgets=try values.decode([Widget].self,forKey:.widgets)
        layoutGridRevision=try values.decodeIfPresent(Int.self,forKey:.layoutGridRevision) ?? 0
        if layoutGridRevision < 1 {
            for index in widgets.indices {
                let kind = widgets[index].kind
                if widgets[index].frame == DashboardGrid.legacyDefaultFrame(for: kind),
                   let frame = DashboardGrid.defaultFrame(for: kind) {
                    widgets[index].frame = frame
                }
            }
            layoutGridRevision = 1
        }
        textScale=try values.decodeIfPresent(Double.self,forKey:.textScale) ?? 1
        remoteHosts=try values.decodeIfPresent([RemoteHost].self,forKey:.remoteHosts) ?? []
        weatherPlace=try values.decodeIfPresent(String.self,forKey:.weatherPlace) ?? ""
        latitude=try values.decodeIfPresent(Double.self,forKey:.latitude)
        longitude=try values.decodeIfPresent(Double.self,forKey:.longitude)
        fahrenheit=try values.decodeIfPresent(Bool.self,forKey:.fahrenheit) ?? false
        // Older layouts stored one shared choice. Presence of the widget key marks migration,
        // including an explicitly empty choice, so later-added widgets never inherit it.
        struct WeatherMigration: Decodable { var weatherOptions: WeatherWidgetOptions? }
        let migrations=try values.decode([WeatherMigration].self,forKey:.widgets)
        for index in widgets.indices where widgets[index].kind == .weather && migrations[index].weatherOptions == nil {
            widgets[index].weatherOptions=WeatherWidgetOptions(place:weatherPlace,latitude:latitude,longitude:longitude,fahrenheit:fahrenheit)
        }
        displayID=try values.decodeIfPresent(UInt32.self,forKey:.displayID)
        presentationEnabled=try values.decodeIfPresent(Bool.self,forKey:.presentationEnabled) ?? false
        previewMode=try values.decodeIfPresent(Bool.self,forKey:.previewMode) ?? false
        previewWidthMM=try values.decodeIfPresent(Double.self,forKey:.previewWidthMM) ?? 111
    }
    public static var defaultLayout: DashboardDocument {
        DashboardDocument(widgets: [.agents, .music, .calendar, .weather, .system].compactMap { kind in
            DashboardGrid.defaultFrame(for: kind).map { Widget(kind: kind, frame: $0) }
        })
    }
    public mutating func repairGeometry() {
        textScale = min(1.6, max(0.8, textScale.isFinite ? textScale : 1))
        for index in widgets.indices { widgets[index].frame = widgets[index].frame.clamped(for: widgets[index].kind) }
    }
}
