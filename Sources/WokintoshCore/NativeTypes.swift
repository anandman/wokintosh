import Foundation

public struct NowPlayingInfo: Equatable, Sendable {
    public var title: String; public var artist: String; public var album: String
    public var isPlaying: Bool; public var position: Double; public var duration: Double
    public var updatedAt: Date; public var artworkURL: URL?; public var status: String
    public init(title: String = "", artist: String = "", album: String = "", isPlaying: Bool = false, position: Double = 0, duration: Double = 0, updatedAt: Date = Date(), artworkURL: URL? = nil, status: String = "Connect Apple Music") {
        self.title = title; self.artist = artist; self.album = album; self.isPlaying = isPlaying
        self.position = position; self.duration = duration; self.updatedAt = updatedAt; self.artworkURL = artworkURL; self.status = status
    }
    public var hasTrack: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
public struct WeatherInfo: Equatable, Sendable {
    public var temperature: Double?; public var condition: String; public var symbol: String
    public var status: String; public var place: String; public var updatedAt: Date?
    public init(temperature: Double? = nil, condition: String = "", symbol: String = "cloud.fill", status: String = "Choose a weather location in Settings", place: String = "", updatedAt: Date? = nil) {
        self.temperature = temperature; self.condition = condition; self.symbol = symbol; self.status = status; self.place = place; self.updatedAt = updatedAt
    }
}
public struct WeatherWidgetOptions: Codable, Equatable, Sendable {
    public var place: String
    public var latitude: Double?
    public var longitude: Double?
    public var fahrenheit: Bool
    public init(place: String = "", latitude: Double? = nil, longitude: Double? = nil, fahrenheit: Bool = false) {
        self.place = place; self.latitude = latitude; self.longitude = longitude; self.fahrenheit = fahrenheit
    }
    private enum CodingKeys: String, CodingKey { case place, latitude, longitude, fahrenheit }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        place = try values.decodeIfPresent(String.self, forKey: .place) ?? ""
        latitude = try values.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try values.decodeIfPresent(Double.self, forKey: .longitude)
        fahrenheit = try values.decodeIfPresent(Bool.self, forKey: .fahrenheit) ?? false
    }
}
/// The URL defines the provider request; the token rejects a response after removal/reconfiguration.
public struct WeatherWidgetRequest: Equatable, Sendable {
    public let url: URL
    fileprivate let token: UUID
}

/// Keeps each widget's display choice separate while sharing identical provider requests.
public struct WeatherWidgetState: Sendable {
    private var choices: [UUID: WeatherWidgetOptions] = [:]
    private var results: [URL: WeatherInfo] = [:]
    private var pending: [URL: UUID] = [:]
    public init() {}

    public mutating func setWidgets(_ widgets: [Widget]) {
        choices = Dictionary(widgets.filter { $0.kind == .weather }.map { ($0.id, $0.weatherOptions) }, uniquingKeysWith: { first, _ in first })
        let activeURLs = Set(choices.values.compactMap(Self.requestURL))
        results = results.filter { activeURLs.contains($0.key) }
        pending = pending.filter { activeURLs.contains($0.key) }
    }

    public mutating func synchronize(widgets: [Widget]) -> [WeatherWidgetRequest] {
        setWidgets(widgets)
        let activeURLs = Set(choices.values.compactMap(Self.requestURL))
        return activeURLs.sorted { $0.absoluteString < $1.absoluteString }.compactMap { url in
            guard pending[url] == nil else { return nil }
            let token = UUID()
            pending[url] = token
            return WeatherWidgetRequest(url: url, token: token)
        }
    }

    public mutating func complete(_ request: WeatherWidgetRequest, with info: WeatherInfo) {
        guard pending[request.url] == request.token else { return }
        pending.removeValue(forKey: request.url)
        results[request.url] = info
    }

    public func weather(for widget: Widget) -> WeatherInfo {
        let options = widget.weatherOptions
        let place = Self.displayPlace(options)
        guard widget.kind == .weather, choices[widget.id] == options,
              let url = Self.requestURL(options) else {
            if let latitude = options.latitude, let longitude = options.longitude,
               (try? NativeSourceRequest.weatherURL(latitude: latitude, longitude: longitude, fahrenheit: options.fahrenheit)) == nil {
                return WeatherInfo(status: NativeSourceError.invalidCoordinates.localizedDescription, place: place)
            }
            return WeatherInfo(place: place)
        }
        var info = results[url] ?? WeatherInfo(place: place)
        info.place = place
        return info
    }

    private static func requestURL(_ options: WeatherWidgetOptions) -> URL? {
        guard let latitude = options.latitude, let longitude = options.longitude else { return nil }
        return try? NativeSourceRequest.weatherURL(latitude: latitude, longitude: longitude, fahrenheit: options.fahrenheit)
    }
    private static func displayPlace(_ options: WeatherWidgetOptions) -> String {
        let place = options.place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard place.isEmpty, let latitude = options.latitude, let longitude = options.longitude else { return place }
        return String(format: "%.2f, %.2f", latitude, longitude)
    }
}
public struct CalendarDescriptor: Identifiable, Equatable, Sendable {
    public var id: String; public var title: String; public var sourceTitle: String
    public init(id: String, title: String, sourceTitle: String) {
        self.id = id; self.title = title; self.sourceTitle = sourceTitle
    }
}
public struct CalendarSelectionOptions: Codable, Equatable, Sendable {
    /// nil selects every calendar; an empty array selects none.
    public var calendarIDs: [String]?
    public var includeAllDay: Bool
    public var nextEventOnly: Bool
    public var excludedTitlePatterns: [String]
    public var collapseMirrors: Bool
    public init(calendarIDs: [String]? = nil, includeAllDay: Bool = true, nextEventOnly: Bool = true,
                excludedTitlePatterns: [String] = [], collapseMirrors: Bool = true) {
        self.calendarIDs = calendarIDs; self.includeAllDay = includeAllDay; self.nextEventOnly = nextEventOnly
        self.excludedTitlePatterns = excludedTitlePatterns; self.collapseMirrors = collapseMirrors
    }
    private enum CodingKeys: String, CodingKey { case calendarIDs, includeAllDay, nextEventOnly, excludedTitlePatterns, collapseMirrors }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        calendarIDs = try values.decodeIfPresent([String].self, forKey: .calendarIDs)
        includeAllDay = try values.decodeIfPresent(Bool.self, forKey: .includeAllDay) ?? true
        nextEventOnly = try values.decodeIfPresent(Bool.self, forKey: .nextEventOnly) ?? true
        excludedTitlePatterns = try values.decodeIfPresent([String].self, forKey: .excludedTitlePatterns) ?? []
        collapseMirrors = try values.decodeIfPresent(Bool.self, forKey: .collapseMirrors) ?? true
    }
}
public struct CalendarEntry: Identifiable, Equatable, Sendable {
    public var id: String; public var title: String; public var startDate: Date; public var endDate: Date; public var isAllDay: Bool
    public var calendarID: String; public var calendarTitle: String
    public init(id: String, title: String, startDate: Date, endDate: Date, isAllDay: Bool, calendarID: String = "", calendarTitle: String = "") {
        self.id = id; self.title = title; self.startDate = startDate; self.endDate = endDate; self.isAllDay = isAllDay
        self.calendarID = calendarID; self.calendarTitle = calendarTitle
    }
}
public extension CalendarEntry {
    func compactDateLabel(relativeTo now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let format = DateFormatter()
        format.locale=locale; format.calendar=calendar; format.timeZone=calendar.timeZone
        format.dateStyle = .none; format.timeStyle = .short
        let time = isAllDay ? "All day" : format.string(from: startDate)
        if calendar.isDate(startDate, inSameDayAs: now) { return time }
        let day: String
        if let tomorrow=calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(startDate, inSameDayAs: tomorrow) {
            day="Tomorrow"
        } else {
            format.setLocalizedDateFormatFromTemplate("EEE")
            day=format.string(from: startDate)
        }
        return "\(day) · \(time)"
    }
}
public struct CalendarInfo: Equatable, Sendable {
    public var events: [CalendarEntry]; public var status: String; public var authorized: Bool
    public var calendars: [CalendarDescriptor]
    public init(events: [CalendarEntry] = [], status: String = "Enable Calendar to show upcoming events", authorized: Bool = false, calendars: [CalendarDescriptor] = []) {
        self.events = events; self.status = status; self.authorized = authorized; self.calendars = calendars
    }
    public func events(for options: CalendarSelectionOptions, at now: Date = Date()) -> [CalendarEntry] {
        let selectedIDs = options.calendarIDs.map(Set.init)
        let excluded = options.excludedTitlePatterns.flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        let selected = events.filter { event in
            event.startDate.timeIntervalSinceReferenceDate.isFinite &&
            event.endDate.timeIntervalSinceReferenceDate.isFinite &&
            event.endDate > event.startDate && event.endDate > now &&
            (selectedIDs?.contains(event.calendarID) ?? true) &&
            (options.includeAllDay || !event.isAllDay) &&
            !excluded.contains(where: { event.title.lowercased().contains($0) })
        }
        // Mirroring services write separate busy blocks. A generic title is only a mirror
        // when a selected, visible original has the exact interval; overlap alone is insufficient.
        let originals = Set(selected.filter { !Self.isGenericMirrorTitle($0.title) }.map(CalendarInterval.init))
        return Array(selected.filter { event in
            !options.collapseMirrors || !Self.isGenericMirrorTitle(event.title) || !originals.contains(CalendarInterval(event))
        }.sorted { first, second in
            if first.startDate != second.startDate { return first.startDate < second.startDate }
            if first.title != second.title { return first.title < second.title }
            return first.id < second.id
        }.prefix(options.nextEventOnly ? 1 : 12))
    }
    private struct CalendarInterval: Hashable {
        var start: Date; var end: Date; var allDay: Bool
        init(_ event: CalendarEntry) { start = event.startDate; end = event.endDate; allDay = event.isAllDay }
    }
    private static func isGenericMirrorTitle(_ title: String) -> Bool {
        let normalized = title.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return ["blocked time", "busy", "private appointment"].contains(normalized)
    }
}
public struct PlaceResult: Identifiable, Equatable, Sendable {
    public var id: Int; public var name: String; public var country: String; public var latitude: Double; public var longitude: Double
    public init(id: Int, name: String, country: String, latitude: Double, longitude: Double) {
        self.id = id; self.name = name; self.country = country; self.latitude = latitude; self.longitude = longitude
    }
    public var label: String { country.isEmpty ? name : "\(name), \(country)" }
}
public enum NativeSourceError: LocalizedError {
    case invalidCoordinates, invalidResponse, service(String)
    public var errorDescription: String? {
        switch self {
        case .invalidCoordinates: return "Choose valid weather coordinates in Settings"
        case .invalidResponse: return "The source returned an incomplete response"
        case .service(let reason): return reason
        }
    }
}
public enum NativeSourceParser {
    public static func music(from data: Data, at date: Date = Date()) throws -> NowPlayingInfo {
        struct Response: Decodable {
            var title: String
            var artist: String?; var album: String?; var isPlaying: Bool?
            var position: Double?; var duration: Double?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let duration = max(0, response.duration ?? 0)
        let hasTrack = !response.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let playing = hasTrack && (response.isPlaying ?? false)
        return NowPlayingInfo(title: response.title, artist: response.artist ?? "", album: response.album ?? "",
                              isPlaying: playing, position: min(duration, max(0, response.position ?? 0)),
                              duration: duration, updatedAt: date,
                              status: hasTrack ? (playing ? "Playing" : "Paused") : "No current track")
    }

    public static func weather(from data: Data, place: String) throws -> WeatherInfo {
        struct Current: Decodable {
            var time: Double; var temperature_2m: Double; var weather_code: Int; var is_day: Int
        }
        struct Response: Decodable {
            var current: Current?; var error: Bool?; var reason: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.error == true { throw NativeSourceError.service(response.reason ?? "Weather service unavailable") }
        guard let current = response.current else { throw NativeSourceError.invalidResponse }
        let description = condition(code: current.weather_code, isDay: current.is_day != 0)
        return WeatherInfo(temperature: current.temperature_2m, condition: description.condition,
                           symbol: description.symbol, status: "Open-Meteo", place: place,
                           updatedAt: Date(timeIntervalSince1970: current.time))
    }

    public static func places(from data: Data) throws -> [PlaceResult] {
        struct Place: Decodable {
            var id: Int; var name: String; var country: String?; var latitude: Double; var longitude: Double
        }
        struct Response: Decodable { var results: [Place]?; var error: Bool?; var reason: String? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.error == true { throw NativeSourceError.service(response.reason ?? "Location search unavailable") }
        return (response.results ?? []).filter { (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }
            .map { PlaceResult(id: $0.id, name: $0.name, country: $0.country ?? "", latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// WMO interpretation codes returned by Open-Meteo, including the provider's day/night flag.
    public static func condition(code: Int, isDay: Bool) -> (condition: String, symbol: String) {
        switch code {
        case 0: return ("Clear", isDay ? "sun.max.fill" : "moon.stars.fill")
        case 1: return ("Mostly clear", isDay ? "sun.max.fill" : "moon.stars.fill")
        case 2: return ("Partly cloudy", isDay ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3: return ("Overcast", "cloud.fill")
        case 45, 48: return ("Fog", "cloud.fog.fill")
        case 51, 53, 55: return ("Drizzle", "cloud.drizzle.fill")
        case 56, 57: return ("Freezing drizzle", "cloud.sleet.fill")
        case 61, 63, 65: return ("Rain", "cloud.rain.fill")
        case 66, 67: return ("Freezing rain", "cloud.sleet.fill")
        case 71, 73, 75, 77: return ("Snow", "cloud.snow.fill")
        case 80, 81, 82: return ("Rain showers", "cloud.heavyrain.fill")
        case 85, 86: return ("Snow showers", "cloud.snow.fill")
        case 95, 96, 99: return ("Thunderstorm", "cloud.bolt.rain.fill")
        default: return ("Unknown conditions", "questionmark.circle")
        }
    }
}

public enum NativeSourceRequest {
    public static func weatherURL(latitude: Double, longitude: Double, fahrenheit: Bool) throws -> URL {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw NativeSourceError.invalidCoordinates
        }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [URLQueryItem(name: "latitude", value: String(latitude)), URLQueryItem(name: "longitude", value: String(longitude)),
                          URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
                          URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
                          URLQueryItem(name: "timeformat", value: "unixtime"), URLQueryItem(name: "forecast_days", value: "1")]
        return url.url!
    }

    public static func geocodingURL(query: String) -> URL? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return nil }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [URLQueryItem(name: "name", value: String(term.prefix(200))), URLQueryItem(name: "count", value: "8"),
                          URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json")]
        return url.url
    }
}
