import XCTest
@testable import WokintoshCore

final class NativeOptionsTests: XCTestCase {
    private let frame = WidgetFrame(x: 0, y: 0, width: 0.25, height: 0.25)

    func testLegacyGlobalLocationMigratesIntoExistingWeatherWidgetsOnly() throws {
        let weatherA = Widget(kind: .weather, frame: frame)
        let weatherB = Widget(kind: .weather, frame: frame)
        let clock = Widget(kind: .clock, frame: frame)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DashboardDocument(widgets: [weatherA, weatherB, clock]))) as? [String: Any])
        var widgets = try XCTUnwrap(json["widgets"] as? [[String: Any]])
        for index in widgets.indices { widgets[index].removeValue(forKey: "weatherOptions") }
        json["widgets"] = widgets
        json["weatherPlace"] = "Oslo"; json["latitude"] = 59.91; json["longitude"] = 10.75; json["fahrenheit"] = true
        let document = try JSONDecoder().decode(DashboardDocument.self, from: JSONSerialization.data(withJSONObject: json))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        let savedWidgets = try XCTUnwrap(saved["widgets"] as? [[String: Any]])
        let first = try XCTUnwrap(savedWidgets[0]["weatherOptions"] as? [String: Any])
        let second = try XCTUnwrap(savedWidgets[1]["weatherOptions"] as? [String: Any])
        XCTAssertEqual(first["place"] as? String, "Oslo")
        XCTAssertEqual(first["latitude"] as? Double, 59.91)
        XCTAssertEqual(first["fahrenheit"] as? Bool, true)
        XCTAssertEqual(second["longitude"] as? Double, 10.75)
        XCTAssertNotEqual((savedWidgets[2]["weatherOptions"] as? [String: Any])?["place"] as? String, "Oslo")
    }

    func testExplicitEmptyWidgetChoiceDoesNotAdoptLegacyLocation() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DashboardDocument(widgets: [Widget(kind: .weather, frame: frame)]))) as? [String: Any])
        var widgets = try XCTUnwrap(json["widgets"] as? [[String: Any]])
        widgets[0]["weatherOptions"] = ["place": "", "fahrenheit": false]
        json["widgets"] = widgets
        json["weatherPlace"] = "Oslo"; json["latitude"] = 59.91; json["longitude"] = 10.75
        let document = try JSONDecoder().decode(DashboardDocument.self, from: JSONSerialization.data(withJSONObject: json))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        let savedWidgets = try XCTUnwrap(saved["widgets"] as? [[String: Any]])
        let options = try XCTUnwrap(savedWidgets[0]["weatherOptions"] as? [String: Any])
        XCTAssertEqual(options["place"] as? String, "")
        XCTAssertNil(options["latitude"])
    }
    private func weather(_ place: String, latitude: Double, longitude: Double, fahrenheit: Bool = false) -> Widget {
        var widget = Widget(kind: .weather, frame: frame)
        widget.weatherOptions = WeatherWidgetOptions(place: place, latitude: latitude, longitude: longitude, fahrenheit: fahrenheit)
        return widget
    }

    func testTwoWidgetLocationsAndUnitsHaveIndependentRequestKeysAndResults() throws {
        let oslo = weather("Oslo", latitude: 59.91, longitude: 10.75)
        let tokyo = weather("Tokyo", latitude: 35.68, longitude: 139.69, fahrenheit: true)
        let restored = try JSONDecoder().decode(DashboardDocument.self, from: JSONEncoder().encode(DashboardDocument(widgets: [oslo, tokyo])))
        XCTAssertEqual(restored.widgets.map(\.weatherOptions), [oslo.weatherOptions, tokyo.weatherOptions])
        var state = WeatherWidgetState()
        let requests = state.synchronize(widgets: [oslo, tokyo])
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let query = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
            let isOslo = query.first(where: { $0.name == "latitude" })?.value == "59.91"
            XCTAssertEqual(query.first(where: { $0.name == "temperature_unit" })?.value, isOslo ? "celsius" : "fahrenheit")
            state.complete(request, with: WeatherInfo(temperature: isOslo ? 4 : 68, place: "provider label"))
        }
        XCTAssertEqual(state.weather(for: oslo).temperature, 4)
        XCTAssertEqual(state.weather(for: oslo).place, "Oslo")
        XCTAssertEqual(state.weather(for: tokyo).temperature, 68)
        XCTAssertEqual(state.weather(for: tokyo).place, "Tokyo")
    }

    func testSameEndpointIsReadOnceWhilePendingAndKeepsEachWidgetLabel() throws {
        let first = weather("Home", latitude: 1, longitude: 2)
        let second = weather("Nearby", latitude: 1, longitude: 2)
        var state = WeatherWidgetState()
        let request = try XCTUnwrap(state.synchronize(widgets: [first, second]).first)
        XCTAssertEqual(state.synchronize(widgets: [first, second]), [])
        state.complete(request, with: WeatherInfo(temperature: 23))
        XCTAssertEqual(state.weather(for: first).place, "Home")
        XCTAssertEqual(state.weather(for: second).place, "Nearby")
        XCTAssertEqual(state.weather(for: second).temperature, 23)
        var fahrenheit = second
        fahrenheit.weatherOptions.fahrenheit = true
        XCTAssertEqual(state.synchronize(widgets: [first, fahrenheit]).count, 2)
        XCTAssertNil(state.weather(for: fahrenheit).temperature)
        XCTAssertEqual(state.weather(for: first).temperature, 23)
    }

    func testOldLocationResponseCannotOverwriteChangedOrRemovedWidget() throws {
        var widget = weather("First", latitude: 1, longitude: 2)
        var state = WeatherWidgetState()
        let oldRequest = try XCTUnwrap(state.synchronize(widgets: [widget]).first)
        widget.weatherOptions = WeatherWidgetOptions(place: "Second", latitude: 3, longitude: 4)
        let newRequest = try XCTUnwrap(state.synchronize(widgets: [widget]).first)
        state.complete(newRequest, with: WeatherInfo(temperature: 31))
        state.complete(oldRequest, with: WeatherInfo(temperature: -20))
        XCTAssertEqual(state.weather(for: widget).temperature, 31)
        let pending = try XCTUnwrap(state.synchronize(widgets: [widget]).first)
        state.setWidgets([])
        state.complete(pending, with: WeatherInfo(temperature: 99))
        XCTAssertNil(state.weather(for: widget).temperature)
        let readded = try XCTUnwrap(state.synchronize(widgets: [widget]).first)
        state.complete(pending, with: WeatherInfo(temperature: 99))
        XCTAssertNil(state.weather(for: widget).temperature)
        state.complete(readded, with: WeatherInfo(temperature: 32))
        XCTAssertEqual(state.weather(for: widget).temperature, 32)
    }

    func testNewWidgetStaysUnconfiguredAfterMigratedDocumentRoundTrip() throws {
        var document = DashboardDocument(widgets: [weather("Oslo", latitude: 59.91, longitude: 10.75)])
        document.weatherPlace = "Old global"; document.latitude = 40; document.longitude = 50; document.fahrenheit = true
        document.widgets.append(Widget(kind: .weather, frame: frame))
        let restored = try JSONDecoder().decode(DashboardDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(restored.widgets[0].weatherOptions.place, "Oslo")
        XCTAssertEqual(restored.widgets[1].weatherOptions, WeatherWidgetOptions())
        var state = WeatherWidgetState()
        XCTAssertEqual(state.synchronize(widgets: restored.widgets).count, 1)
        XCTAssertNil(state.weather(for: restored.widgets[1]).temperature)
    }

    func testInvalidCoordinatesNeverBecomeRequests() {
        let invalid = weather("Invalid", latitude: 91, longitude: 2)
        var state = WeatherWidgetState()
        XCTAssertEqual(state.synchronize(widgets: [invalid]), [])
        XCTAssertTrue(state.weather(for: invalid).status.contains("valid weather coordinates"))
        XCTAssertNil(state.weather(for: invalid).temperature)
    }

}
