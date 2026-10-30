import XCTest
@testable import WokintoshCore

final class CoreTests: XCTestCase {
    func row(_ id: String, host: String = "a", state: AgentState = .working) -> SessionRow {
        SessionRow(hostID: host, hostName: host, session: AgentSession(id: id, provider: "codex", title: id, project: "p", state: state, updatedAt: Date(timeIntervalSince1970: 100)))
    }
    func testSameSessionOnDifferentHostsHasDistinctIdentity() {
        XCTAssertNotEqual(row("same").id, row("same", host: "b").id)
    }
    func testAttentionFirstAndOverflowAreAccurate() {
        let rows = [row("busy"), row("waiting", state: .needsAttention), row("finished", state: .finished)]
        let page = AgentPresentation.make(rows: rows, capacity: 1, showFinished: true)
        XCTAssertEqual(page.visible.map(\.session.id), ["waiting"])
        XCTAssertEqual(page.hiddenCount, 2)
        XCTAssertEqual(page.attentionCount, 1)
    }
    func testZeroCapacityDoesNotLoseSummaryCounts() {
        let page = AgentPresentation.make(rows: [row("waiting", state: .needsAttention)], capacity: 0)
        XCTAssertEqual(page.visible.count, 0)
        XCTAssertEqual(page.hiddenCount, 1)
        XCTAssertEqual(page.attentionCount, 1)
    }
    func testGeometryClampsOffCanvasAndTooSmallWidgets() {
        let frame = WidgetFrame(x: -1, y: 4, width: 0.01, height: 0.01).clamped(for: .agents)
        XCTAssertGreaterThanOrEqual(frame.x, 0)
        XCTAssertLessThanOrEqual(frame.y + frame.height, 1)
        XCTAssertGreaterThanOrEqual(frame.width, 0.25)
        XCTAssertGreaterThanOrEqual(frame.height, 0.2)
    }
    func testNonfiniteGeometryIsRepaired() {
        let frame = WidgetFrame(x: .nan, y: .infinity, width: .nan, height: -.infinity).clamped(for: .music)
        XCTAssertTrue(frame.x.isFinite && frame.y.isFinite && frame.width.isFinite && frame.height.isFinite)
    }
    func testDefaultLayoutSurvivesEncodingAndResizing() throws {
        var document = DashboardDocument.defaultLayout
        XCTAssertFalse(document.widgets.isEmpty)
        guard !document.widgets.isEmpty else { return }
        document.widgets[0].frame = WidgetFrame(x: 0.2, y: 0.1, width: 0.6, height: 0.5)
        let data = try JSONEncoder().encode(document)
        let recovered = try JSONDecoder().decode(DashboardDocument.self, from: data)
        XCTAssertEqual(document, recovered)
        XCTAssertEqual(Set(recovered.widgets.map(\.kind)), Set([.agents, .music, .calendar, .weather, .system]))
    }
    func testSnapshotDecodesFractionalTimesAndFutureStateSafely() throws {
        let json = #"{"schemaVersion":1,"host":{"id":"linux","name":"Linux","platform":"linux"},"generatedAt":"2026-10-29T22:00:00.123Z","sessions":[{"id":"a","provider":"codex","title":"Task","project":"p","state":"future-state","updatedAt":"2026-10-29T22:00:00Z"}],"system":{}}"#
        let snapshot = try Snapshot.decode(Data(json.utf8))
        XCTAssertEqual(snapshot.sessions.first?.state, .unknown)
        XCTAssertEqual(snapshot.host.platform, "linux")
    }
    func testOlderLayoutKeepsWidgetsWhenPreferencesAreMissing() throws {
        let widgets = DashboardDocument.defaultLayout.widgets
        let array = try JSONSerialization.jsonObject(with: JSONEncoder().encode(widgets))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "widgets": array])
        let restored = try JSONDecoder().decode(DashboardDocument.self, from: data)
        XCTAssertEqual(restored.widgets, widgets)
        XCTAssertEqual(restored.textScale, 1)
    }
    func testUnsupportedLayoutVersionIsRejected() {
        var value = DashboardDocument.defaultLayout
        value.version=999
        let data=try! JSONEncoder().encode(value)
        XCTAssertThrowsError(try JSONDecoder().decode(DashboardDocument.self, from:data))
    }

    func testRestoredOfflineSelectedSystemNeverSubstitutesLocalReadings() throws {
        var widget = Widget(kind: .system, frame: WidgetFrame(x: 0, y: 0, width: 0.4, height: 0.2))
        widget.hostID = "remote-machine"
        let restored = try JSONDecoder().decode(Widget.self, from: JSONEncoder().encode(widget))
        let local = Snapshot(schemaVersion: 1, host: HostInfo(id: "local-machine", name: "Local Mac", platform: "macos"), generatedAt: .now, sessions: [], system: SystemReading(cpuPercent: 74))
        let feeds = ["local": FeedStatus(name: "This Mac", snapshot: local), "remote": FeedStatus(name: "Dev Mini", error: "Offline")]
        let result = SystemPresentation.resolve(hostID: restored.hostID, feeds: feeds)
        XCTAssertEqual(result.0, "Selected machine")
        XCTAssertEqual(result.1, SystemReading())
        XCTAssertFalse(result.2)
        XCTAssertEqual(restored.hostID, "remote-machine")
        let removed = SystemPresentation.resolve(hostID: restored.hostID, feeds: ["local": feeds["local"]!])
        XCTAssertEqual(removed.1, SystemReading())
        XCTAssertFalse(removed.2)
        let automatic = SystemPresentation.resolve(hostID: nil, feeds: feeds)
        XCTAssertEqual(automatic.0, "Local Mac")
        XCTAssertEqual(automatic.1.cpuPercent, 74)
        XCTAssertTrue(automatic.2)
    }
    func testSelectedSystemKeepsStaleRemoteReadingExplicitlyOffline() {
        let snapshot = Snapshot(schemaVersion: 1, host: HostInfo(id: "remote", name: "Remote", platform: "linux"), generatedAt: .now, sessions: [], system: SystemReading(cpuPercent: 22))
        let result = SystemPresentation.resolve(hostID: "remote", feeds: ["remote": FeedStatus(name: "Dev Mini", snapshot: snapshot, error: "Disconnected")])
        XCTAssertEqual(result.0, "Dev Mini")
        XCTAssertEqual(result.1.cpuPercent, 22)
        XCTAssertFalse(result.2)
    }
    func testMixedAttentionOverflowAlwaysShowsTotalAcrossCapacities() {
        let rows = [row("wait1", state: .needsAttention), row("wait2", state: .needsAttention)] + (0..<10).map { row("work\($0)") }
        for (capacity, hidden, label) in [(0, 12, "+12 more · 2 need you"), (1, 11, "+11 more · 1 needs you"), (6, 6, "+6 more sessions")] {
            let page = AgentPresentation.make(rows: rows, capacity: capacity)
            XCTAssertEqual(page.hiddenCount, hidden)
            XCTAssertEqual(page.overflowLabel, label)
        }
        XCTAssertNil(AgentPresentation.make(rows: rows, capacity: 12).overflowLabel)
    }

}
