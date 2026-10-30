import XCTest
@testable import WokintoshCore

final class NativeSourceTests: XCTestCase {
    func testMusicMetadataPreservesQuotesNewlinesAndUnicode() throws {
        let data = Data(#"{"title":"A \"quoted\" song\nLive","artist":"Björk","album":"One | Two","isPlaying":true,"position":12.5,"duration":240}"#.utf8)
        let music = try NativeSourceParser.music(from: data, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(music.title, "A \"quoted\" song\nLive")
        XCTAssertEqual(music.artist, "Björk")
        XCTAssertTrue(music.hasTrack)
        XCTAssertTrue(music.isPlaying)
        XCTAssertEqual(music.position, 12.5)
    }

    func testMusicNormalizesTimingAndEmptyTrack() throws {
        let music = try NativeSourceParser.music(from: Data(#"{"title":"Song","isPlaying":true,"position":900,"duration":200}"#.utf8))
        XCTAssertEqual(music.position, 200)
        let empty = try NativeSourceParser.music(from: Data(#"{"title":"","isPlaying":true,"position":-20,"duration":-1}"#.utf8))
        XCTAssertFalse(empty.hasTrack)
        XCTAssertFalse(empty.isPlaying)
        XCTAssertEqual(empty.position, 0)
        XCTAssertEqual(empty.duration, 0)
        XCTAssertThrowsError(try NativeSourceParser.music(from: Data("not json".utf8)))
    }

    func testWeatherUsesProviderTimestampAndNightCondition() throws {
        let result = try NativeSourceParser.weather(from: Data(#"{"current":{"time":1700000000,"temperature_2m":-2.4,"weather_code":0,"is_day":0}}"#.utf8), place: "Oslo")
        XCTAssertEqual(result.temperature, -2.4)
        XCTAssertEqual(result.updatedAt, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(result.symbol, "moon.stars.fill")
        XCTAssertEqual(result.place, "Oslo")
        XCTAssertEqual(result.condition, "Clear")
    }

    func testWeatherRejectsMissingCurrentValuesAndAPIErrors() {
        XCTAssertThrowsError(try NativeSourceParser.weather(from: Data(#"{"current":{"weather_code":3}}"#.utf8), place: ""))
        XCTAssertThrowsError(try NativeSourceParser.weather(from: Data(#"{"error":true,"reason":"Bad coordinates"}"#.utf8), place: ""))
        XCTAssertEqual(NativeSourceParser.condition(code: 95, isDay: true).symbol, "cloud.bolt.rain.fill")
        XCTAssertEqual(NativeSourceParser.condition(code: 999, isDay: true).condition, "Unknown conditions")
    }

    func testPlaceSearchHandlesMissingCountryAndNoResults() throws {
        let places = try NativeSourceParser.places(from: Data(#"{"results":[{"id":1,"name":"Springfield","latitude":39.8,"longitude":-89.6,"country":"United States"},{"id":2,"name":"Remote","latitude":0,"longitude":0}]}"#.utf8))
        XCTAssertEqual(places.map(\.label), ["Springfield, United States", "Remote"])
        XCTAssertEqual(try NativeSourceParser.places(from: Data("{}".utf8)), [])
        XCTAssertThrowsError(try NativeSourceParser.places(from: Data(#"{"error":true,"reason":"Invalid search"}"#.utf8)))
    }

    func testRequestCoordinatesAndUnitAreExplicit() throws {
        let url = try NativeSourceRequest.weatherURL(latitude: 0, longitude: 0, fahrenheit: true)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "temperature_unit" }?.value, "fahrenheit")
        XCTAssertEqual(query.first { $0.name == "timeformat" }?.value, "unixtime")
        XCTAssertThrowsError(try NativeSourceRequest.weatherURL(latitude: .nan, longitude: 0, fahrenheit: false))
        XCTAssertThrowsError(try NativeSourceRequest.weatherURL(latitude: 91, longitude: 0, fahrenheit: false))
        XCTAssertThrowsError(try NativeSourceRequest.weatherURL(latitude: 0, longitude: -181, fahrenheit: false))
        let search = NativeSourceRequest.geocodingURL(query: "São Paulo & Coast")!
        XCTAssertEqual(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value, "São Paulo & Coast")
        XCTAssertNil(NativeSourceRequest.geocodingURL(query: " x "))
    }
    func testCompactCalendarDistinguishesTodayTomorrowAndLaterDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 18))!
        for (day, allDay, expected) in [(29, false, "9:30\u{202F}AM"), (30, false, "Tomorrow · 9:30\u{202F}AM"), (2, true, "Mon · All day")] {
            let start = calendar.date(from: DateComponents(year: 2026, month: day == 2 ? 11 : 10, day: day, hour: 9, minute: 30))!
            let event = CalendarEntry(id: "event", title: "Event", startDate: start, endDate: start, isAllDay: allDay)
            XCTAssertEqual(event.compactDateLabel(relativeTo: now, calendar: calendar, locale: Locale(identifier: "en_US_POSIX")), expected)
        }
    }

}
