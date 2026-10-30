import AppKit
import Carbon
import Combine
import EventKit
import WokintoshCore

/// Permission requests are confined to explicit Connect / Enable actions.
@MainActor final class NativeSources: ObservableObject {
    @Published var music = NowPlayingInfo()
    @Published var weather = WeatherInfo()
    @Published var calendar = CalendarInfo()
    @Published var musicEnabled: Bool {
        didSet { defaults.set(musicEnabled, forKey: Self.musicOptInKey) }
    }

    private static let musicOptInKey = "wokintosh.musicEnabled"
    private let defaults: UserDefaults
    private let musicReader = MusicSource()
    private let calendarReader = CalendarSource()
    private let weatherReader = WeatherSource()
    private var musicRefreshing = false
    private var calendarRefreshing = false
    private var weatherRequestID = UUID()
    private var pendingWeatherURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        musicEnabled = defaults.bool(forKey: Self.musicOptInKey)
    }

    func refresh(document: DashboardDocument) async {
        let kinds = Set(document.widgets.map(\.kind))
        async let musicUpdate: Void = refreshMusicIfVisible(kinds.contains(.music))
        async let calendarUpdate: Void = refreshCalendarIfVisible(kinds.contains(.calendar))
        async let weatherUpdate: Void = refreshWeather(document: document, visible: kinds.contains(.weather))
        _ = await (musicUpdate, calendarUpdate, weatherUpdate)
    }

    func connectMusic() async {
        musicEnabled = true
        await updateMusic(allowPrompt: true)
    }

    func requestCalendarAccess() async {
        guard !calendarRefreshing else { return }
        calendarRefreshing = true
        defer { calendarRefreshing = false }
        calendar = await calendarReader.requestAccess()
    }

    func performPlayback(_ action: String) async {
        guard ["playpause", "next", "previous"].contains(action) else { return }
        guard musicIsRunning else {
            music = NowPlayingInfo(status: "Open Apple Music to use playback controls")
            return
        }
        do {
            // This user click authorizes the selected media action and any required consent prompt.
            try await musicReader.playback(action)
            musicEnabled = true
            await updateMusic(allowPrompt: false)
        } catch {
            music.status = error.localizedDescription
        }
    }

    func searchPlaces(query: String) async throws -> [PlaceResult] {
        try await weatherReader.search(query: query)
    }

    private var musicIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" && !$0.isTerminated }
    }

    private func refreshMusicIfVisible(_ visible: Bool) async {
        guard visible, musicEnabled else { return }
        await updateMusic(allowPrompt: false)
    }

    private func updateMusic(allowPrompt: Bool) async {
        guard !musicRefreshing else { return }
        guard musicIsRunning else {
            music = NowPlayingInfo(status: "Open Apple Music to show Now Playing")
            return
        }
        musicRefreshing = true
        defer { musicRefreshing = false }
        do {
            let result = try await musicReader.read(allowPrompt: allowPrompt)
            guard musicEnabled else { return }
            music = result
        } catch let error as MusicPermissionError {
            // Expose Connect again if a new app identity needs consent or access was revoked.
            musicEnabled = false
            music = NowPlayingInfo(status: error.localizedDescription)
        } catch {
            music = NowPlayingInfo(status: "Apple Music unavailable: \(error.localizedDescription)")
        }
    }

    private func refreshCalendarIfVisible(_ visible: Bool) async {
        guard visible, !calendarRefreshing else { return }
        calendarRefreshing = true
        defer { calendarRefreshing = false }
        calendar = await calendarReader.read()
    }

    private func refreshWeather(document: DashboardDocument, visible: Bool) async {
        guard visible else {
            weatherRequestID = UUID()
            pendingWeatherURL = nil
            return
        }
        guard let latitude = document.latitude, let longitude = document.longitude else {
            weatherRequestID = UUID()
            pendingWeatherURL = nil
            weather = WeatherInfo(place: document.weatherPlace)
            return
        }
        do {
            let url = try NativeSourceRequest.weatherURL(latitude: latitude, longitude: longitude, fahrenheit: document.fahrenheit)
            guard pendingWeatherURL != url else { return }
            let requestID = UUID()
            weatherRequestID = requestID
            pendingWeatherURL = url
            defer { if weatherRequestID == requestID { pendingWeatherURL = nil } }
            let place = document.weatherPlace.isEmpty ? String(format: "%.2f, %.2f", latitude, longitude) : document.weatherPlace
            let result = await weatherReader.read(url: url, place: place)
            guard weatherRequestID == requestID else { return }
            weather = result
        } catch {
            weatherRequestID = UUID()
            pendingWeatherURL = nil
            weather = WeatherInfo(status: error.localizedDescription, place: document.weatherPlace)
        }
    }
}

private enum MusicPermissionError: LocalizedError {
    case needsConsent, denied, unavailable
    var errorDescription: String? {
        switch self {
        case .needsConsent: return "Connect Apple Music to allow access"
        case .denied: return "Allow Wokintosh in System Settings → Privacy & Security → Automation, then connect again"
        case .unavailable: return "Apple Music is no longer running"
        }
    }
}

/// Process execution, artwork I/O, and Apple Events consent preflight all run off the main actor.
private actor MusicSource {
    private var artworkCache: [String: URL] = [:]
    private var artworkAttempts: [String: Date] = [:]
    private var artworkDirectory: URL?

    deinit {
        if let directory = artworkDirectory { try? FileManager.default.removeItem(at: directory) }
    }

    private func checkPermission(allowPrompt: Bool) throws {
        var target = AEAddressDesc()
        let bundleID = "com.apple.Music"
        let result = bundleID.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, bundleID.utf8.count, &target) }
        guard result == noErr else { throw MusicPermissionError.unavailable }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), allowPrompt)
        switch status {
        case noErr: return
        case OSStatus(errAEEventWouldRequireUserConsent): throw MusicPermissionError.needsConsent
        case OSStatus(errAEEventNotPermitted): throw MusicPermissionError.denied
        default: throw MusicPermissionError.unavailable
        }
    }

    func read(allowPrompt: Bool) throws -> NowPlayingInfo {
        try checkPermission(allowPrompt: allowPrompt)
        let data = try CommandRunner.run("/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", Self.metadataScript], timeout: 4, maxBytes: 256 * 1024)
        var info = try NativeSourceParser.music(from: data)
        guard info.hasTrack else { return info }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let persistentID = object?["trackID"] as? String ?? ""
        // IDs remain separate from display text; external strings are always argv, never script source.
        let key = persistentID.isEmpty ? [info.title, info.artist, info.album, String(info.duration)].joined(separator: "\u{0}") : persistentID
        if let cached = artworkCache[key], FileManager.default.fileExists(atPath: cached.path) {
            info.artworkURL = cached
        } else if Date().timeIntervalSince(artworkAttempts[key] ?? .distantPast) >= 60 {
            artworkAttempts[key] = Date()
            info.artworkURL = try? fetchArtwork(trackID: persistentID)
            if let artworkURL = info.artworkURL { artworkCache[key] = artworkURL }
            if artworkCache.count > 12 {
                let expired = artworkCache.filter { $0.key != key }
                for (oldKey, url) in expired { try? FileManager.default.removeItem(at: url); artworkCache.removeValue(forKey: oldKey) }
            }
            if artworkAttempts.count > 100 { artworkAttempts = [key: Date()] }
        }
        return info
    }

    func playback(_ action: String) throws {
        let command: String
        switch action {
        case "playpause": command = "playpause"
        case "next": command = "next track"
        case "previous": command = "previous track"
        default: return
        }
        try checkPermission(allowPrompt: true)
        _ = try CommandRunner.run("/usr/bin/osascript", arguments: ["-e", "tell application id \"com.apple.Music\" to \(command)"], timeout: 4, maxBytes: 32 * 1024)
    }

    private func fetchArtwork(trackID: String) throws -> URL? {
        // A stable Music ID lets the export reject a track change between metadata and artwork reads.
        guard !trackID.isEmpty else { return nil }
        if artworkDirectory == nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wokintosh-artwork-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            artworkDirectory = directory
        }
        guard let directory = artworkDirectory else { return nil }
        let rawURL = directory.appendingPathComponent(UUID().uuidString + ".raw")
        defer { try? FileManager.default.removeItem(at: rawURL) }
        _ = try CommandRunner.run("/usr/bin/osascript", arguments: ["-e", Self.artworkScript, rawURL.path, trackID], timeout: 4, maxBytes: 32 * 1024)
        let size = try rawURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 16 * 1024 * 1024 else { return nil }
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: rawURL)),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        try png.write(to: url, options: .atomic)
        return url
    }

    private static let metadataScript = #"""
    function run() {
        const music = Application('com.apple.Music');
        const state = music.playerState();
        if (state === 'stopped') return JSON.stringify({title:'',isPlaying:false,position:0,duration:0});
        const track = music.currentTrack();
        if (!track.exists()) return JSON.stringify({title:'',isPlaying:false,position:0,duration:0});
        function text(getter) { try { return String(getter() || ''); } catch (_) { return ''; } }
        function number(getter) { try { const n = Number(getter()); return isFinite(n) ? n : 0; } catch (_) { return 0; } }
        return JSON.stringify({title:text(() => track.name()),artist:text(() => track.artist()),
            album:text(() => track.album()),trackID:text(() => track.persistentID()),isPlaying:state === 'playing',
            position:number(() => music.playerPosition()),duration:number(() => track.duration())});
    }
    """#

    private static let artworkScript = #"""
    on run argv
        set outputPath to item 1 of argv
        set expectedID to item 2 of argv
        tell application id "com.apple.Music"
            if player state is stopped then return ""
            if persistent ID of current track is not expectedID then return ""
            if (count artworks of current track) is 0 then return ""
            set imageBytes to raw data of artwork 1 of current track
        end tell
        set outputFile to open for access POSIX file outputPath with write permission
        try
            set eof outputFile to 0
            write imageBytes to outputFile
            close access outputFile
        on error messageText number errorNumber
            try
                close access outputFile
            end try
            error messageText number errorNumber
        end try
        return ""
    end run
    """#
}

private actor CalendarSource {
    private let store = EKEventStore()
    private var cached: CalendarInfo?
    private var fetchedAt = Date.distantPast
    private var changeObserver: NSObjectProtocol?

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    private func observeStoreChangesIfNeeded() {
        guard changeObserver == nil else { return }
        // The callback transfers only this actor reference, never EventKit objects or the notification.
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { [weak self] _ in
            Task { await self?.invalidateCache() }
        }
    }

    private func invalidateCache() {
        cached = nil
        fetchedAt = .distantPast
    }

    func requestAccess() async -> CalendarInfo {
        do {
            guard try await store.requestFullAccessToEvents() else {
                return CalendarInfo(status: "Calendar access denied. Enable it in System Settings → Privacy & Security → Calendars")
            }
            // Explicit Enable refreshes inventory even when no Calendar widget is visible.
            invalidateCache()
            return read()
        } catch {
            return CalendarInfo(status: "Calendar access unavailable: \(error.localizedDescription)")
        }
    }

    func read() -> CalendarInfo {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: break
        case .notDetermined: return CalendarInfo()
        case .denied: return CalendarInfo(status: "Calendar access denied. Enable it in System Settings → Privacy & Security → Calendars")
        case .restricted: return CalendarInfo(status: "Calendar access is restricted on this Mac")
        case .writeOnly: return CalendarInfo(status: "Enable full Calendar access to read upcoming events")
        @unknown default: return CalendarInfo(status: "Calendar access unavailable")
        }
        observeStoreChangesIfNeeded()
        let now = Date()
        if let cached, now.timeIntervalSince(fetchedAt) < 60 { return cached }
        let calendars = store.calendars(for: .event).map { calendar in
            CalendarDescriptor(id: calendar.calendarIdentifier, title: calendar.title, sourceTitle: calendar.source.title)
        }.sorted { first, second in
            if first.sourceTitle != second.sourceTitle { return first.sourceTitle < second.sourceTitle }
            if first.title != second.title { return first.title < second.title }
            return first.id < second.id
        }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86400)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate == $1.startDate ? ($0.title ?? "") < ($1.title ?? "") : $0.startDate < $1.startDate }
            .map { event in CalendarEntry(id: "\(event.eventIdentifier ?? event.calendarItemIdentifier):\(event.startDate.timeIntervalSince1970)",
                                         title: event.title?.isEmpty == false ? event.title : "Untitled event",
                                         startDate: event.startDate, endDate: event.endDate, isAllDay: event.isAllDay,
                                         calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title) }
        // Keep every candidate in this bounded seven-day window; widgets filter before applying their own limits.
        let result = CalendarInfo(events: events, status: events.isEmpty ? "No events in the next 7 days" : "Upcoming · next 7 days", authorized: true, calendars: calendars)
        cached = result
        fetchedAt = now
        return result
    }
}

private actor WeatherSource {
    private struct CacheEntry { var info: WeatherInfo; var fetchedAt: Date }
    private var cache: [URL: CacheEntry] = [:]
    private var failures: [URL: Date] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func read(url: URL, place: String) async -> WeatherInfo {
        let now = Date()
        if let cached = cache[url], now.timeIntervalSince(cached.fetchedAt) < 600 {
            var info = cached.info
            info.place = place
            return info
        }
        // A failed endpoint should not be retried every dashboard tick.
        if let failedAt = failures[url], now.timeIntervalSince(failedAt) < 60 { return unavailable(url: url, place: place) }
        do {
            let data = try await fetch(url)
            let info = try NativeSourceParser.weather(from: data, place: place)
            cache[url] = CacheEntry(info: info, fetchedAt: now)
            failures.removeValue(forKey: url)
            if cache.count > 12 { cache = [url: CacheEntry(info: info, fetchedAt: now)] }
            return info
        } catch {
            failures[url] = Date()
            if failures.count > 24 { failures = [url: Date()] }
            return unavailable(url: url, place: place)
        }
    }

    private func unavailable(url: URL, place: String) -> WeatherInfo {
        var info = cache[url]?.info ?? WeatherInfo(place: place)
        info.place = place
        info.status = info.temperature == nil ? "Weather unavailable. Check the network; retrying shortly" : "Weather unavailable · showing last update"
        return info
    }

    func search(query: String) async throws -> [PlaceResult] {
        guard let url = NativeSourceRequest.geocodingURL(query: query) else { return [] }
        return try NativeSourceParser.places(from: await fetch(url))
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw NativeSourceError.service("Weather service unavailable")
        }
        guard response.expectedContentLength <= 512 * 1024 else { throw NativeSourceError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 512 * 1024 else { throw NativeSourceError.invalidResponse }
            data.append(byte)
        }
        return data
    }
}
