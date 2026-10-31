import XCTest
@testable import WokintoshCore

final class DashboardGridTests: XCTestCase {
    private func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> WidgetFrame {
        WidgetFrame(x: x / 1280, y: y / 682, width: width / 1280, height: height / 682)
    }

    func testDefaultsAlignEveryEdgeAndKeepWeatherAndSystemOnSharedBottom() throws {
        let expected: [(WidgetKind, WidgetFrame)] = [
            (.agents, frame(16, 16, 752, 496)),
            (.music, frame(784, 16, 480, 304)),
            (.calendar, frame(784, 336, 480, 176)),
            (.weather, frame(16, 528, 352, 128)),
            (.system, frame(384, 528, 880, 128))
        ]
        let widgets = DashboardDocument.defaultLayout.widgets
        for (kind, expectedFrame) in expected {
            let widget = try XCTUnwrap(widgets.first { $0.kind == kind })
            XCTAssertEqual(widget.frame, expectedFrame, "Default \(kind) must share the visible grid")
            for edge in [widget.frame.x * 1280, widget.frame.y * 682,
                         (widget.frame.x + widget.frame.width) * 1280,
                         (widget.frame.y + widget.frame.height) * 682] {
                XCTAssertEqual(edge / 16, (edge / 16).rounded(), accuracy: 0.000001)
            }
        }
        let weather = try XCTUnwrap(widgets.first { $0.kind == .weather })
        let system = try XCTUnwrap(widgets.first { $0.kind == .system })
        XCTAssertEqual((weather.frame.y + weather.frame.height) * 682, 656, accuracy: 0.000001)
        XCTAssertEqual(weather.frame.y + weather.frame.height, system.frame.y + system.frame.height)
        XCTAssertLessThan((system.frame.y + system.frame.height) * 682 + 4, 682)
    }

    func testDefaultSystemShowsCPUAndRAMAndTwoDriveGaugesAtNormalScale() throws {
        let system = try XCTUnwrap(DashboardDocument.defaultLayout.widgets.first { $0.kind == .system })
        let layout = SystemMetricLayout(width: system.frame.width * 1280, height: system.frame.height * 682 - 29.5, textScale: 1, count: 4)
        XCTAssertEqual(layout.columns, 4)
        XCTAssertGreaterThanOrEqual(layout.capacity, 4)
        XCTAssertFalse(layout.compact)
    }

    func testLegacyExactDefaultFramesMigrateAndKeepAllWidgetOptions() throws {
        let legacy: [(WidgetKind, WidgetFrame, WidgetFrame)] = [
            (.agents, WidgetFrame(x: 0.018, y: 0.025, width: 0.59, height: 0.72), frame(16, 16, 752, 496)),
            (.music, WidgetFrame(x: 0.625, y: 0.025, width: 0.36, height: 0.44), frame(784, 16, 480, 304)),
            (.calendar, WidgetFrame(x: 0.625, y: 0.49, width: 0.36, height: 0.255), frame(784, 336, 480, 176)),
            (.weather, WidgetFrame(x: 0.018, y: 0.78, width: 0.27, height: 0.195), frame(16, 528, 352, 128)),
            (.system, WidgetFrame(x: 0.305, y: 0.78, width: 0.68, height: 0.195), frame(384, 528, 880, 128))
        ]
        var widgets = legacy.map { Widget(kind: $0.0, frame: $0.1) }
        for index in widgets.indices {
            widgets[index].hostID = "remote"; widgets[index].provider = "codex"
            widgets[index].showFinished = true; widgets[index].showHelpers = true
            widgets[index].systemOptions.showCPU = false
            widgets[index].systemOptions.driveIDs = ["/", "/Volumes/Archive"]
            widgets[index].weatherOptions = WeatherWidgetOptions(place: "Oslo", latitude: 59.91, longitude: 10.75, fahrenheit: true)
        }
        var document = DashboardDocument(widgets: widgets)
        document.snapToGrid = false; document.nativeFullscreen = false; document.textScale = 1.2
        let restored = try restoreWithoutGridRevision(document)
        var expected = widgets
        for index in expected.indices { expected[index].frame = legacy[index].2 }
        XCTAssertEqual(restored.widgets, expected)
        XCTAssertFalse(restored.snapToGrid); XCTAssertFalse(restored.nativeFullscreen)
        XCTAssertEqual(restored.textScale, 1.2)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertEqual(saved["layoutGridRevision"] as? Int, 1)
    }

    func testLegacyCustomAndAlmostDefaultFramesRemainExact() throws {
        let nearDefault = WidgetFrame(x: 0.018.nextUp, y: 0.025, width: 0.59, height: 0.72)
        let custom = frame(19, 31, 517, 279)
        let widgets = [Widget(kind: .agents, frame: nearDefault), Widget(kind: .calendar, frame: custom),
                       Widget(kind: .clock, frame: WidgetFrame(x: 0.018, y: 0.025, width: 0.59, height: 0.72))]
        let restored = try restoreWithoutGridRevision(DashboardDocument(widgets: widgets))
        XCTAssertEqual(restored.widgets, widgets)
    }

    func testCurrentRevisionNeverRemigratesAnIntentionalOldDefaultFrame() throws {
        let widget = Widget(kind: .agents, frame: WidgetFrame(x: 0.018, y: 0.025, width: 0.59, height: 0.72))
        let document = DashboardDocument(widgets: [widget])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        XCTAssertEqual(saved["layoutGridRevision"] as? Int, 1)
        XCTAssertEqual(try JSONDecoder().decode(DashboardDocument.self, from: JSONEncoder().encode(document)), document)
    }

    func testDraggingAtCanvasBoundsEndsOnGridWithoutChangingSize() {
        let start = frame(16, 16, 352, 128)
        let end = WidgetInteraction.moving(start, dx: 5000, dy: 5000, snap: true)
        XCTAssertEqual(end, frame(928, 544, 352, 128))
        XCTAssertEqual(WidgetInteraction.moving(start, dx: -5000, dy: -5000, snap: true), frame(0, 0, 352, 128))
    }

    func testResizeRoundsMinimumOutwardAndClampsAtLastGridLine() {
        let start = frame(16, 16, 752, 496)
        XCTAssertEqual(WidgetInteraction.resizing(start, dx: -5000, dy: -5000, kind: .agents, snap: true), frame(16, 16, 320, 144))
        XCTAssertEqual(WidgetInteraction.resizing(start, dx: 5000, dy: 5000, kind: .agents, snap: true), frame(16, 16, 1264, 656))
    }

    func testResizeSnapsAbsoluteEdgesAndKeepsLegacyCustomOrigin() {
        let start = frame(23, 21, 350, 160)
        XCTAssertEqual(WidgetInteraction.resizing(start, dx: 9, dy: 9, kind: .weather, snap: true), frame(23, 21, 361, 171))
        XCTAssertEqual(WidgetInteraction.resizing(start, dx: -5000, dy: -5000, kind: .weather, snap: true), frame(23, 21, 169, 91))
    }

    func testFreeDraggingAndResizingKeepExactPixelGeometry() {
        let start = frame(23, 21, 350, 160)
        XCTAssertEqual(WidgetInteraction.moving(start, dx: 9, dy: 7, snap: false), frame(32, 28, 350, 160))
        XCTAssertEqual(WidgetInteraction.resizing(start, dx: 9, dy: 7, kind: .weather, snap: false), frame(23, 21, 359, 167))
    }

    func testAnchoredLegacyFrameKeepsReadableMinimumWhenNoGridEndFits() {
        let start = WidgetFrame(x: 0.6, y: 0.88, width: 0.25, height: 0.12)
        let resized = WidgetInteraction.resizing(start, dx: -5000, dy: -5000, kind: .weather, snap: true)
        XCTAssertEqual(resized.x, start.x); XCTAssertEqual(resized.y, start.y)
        XCTAssertEqual(resized.height, 0.12, accuracy: 0.000001)
        XCTAssertEqual(resized.y + resized.height, 1, accuracy: 0.000001)
        let aligned = DashboardGrid.snappedFrame(start, kind: .weather)
        XCTAssertEqual(aligned.y * 682, 576, accuracy: 0.000001)
        XCTAssertEqual(aligned.height * 682, 96, accuracy: 0.000001)
    }

    func testExplicitAlignmentRepairsEveryEdgeAndMinimumForEachKind() {
        let expected: [(WidgetKind, Double, Double)] = [
            (.agents, 320, 144), (.music, 240, 128), (.calendar, 240, 96),
            (.system, 240, 96), (.clock, 192, 96), (.weather, 176, 96)
        ]
        for (kind, width, height) in expected {
            let result = DashboardGrid.snappedFrame(frame(1270, 675, 1, 1), kind: kind)
            XCTAssertEqual(result, frame(1280 - width, 672 - height, width, height))
            XCTAssertEqual(DashboardGrid.snappedFrame(result, kind: kind), result)
        }
        let repaired = DashboardGrid.snappedFrame(WidgetFrame(x: .nan, y: .infinity, width: .nan, height: -.infinity), kind: .weather)
        XCTAssertEqual(repaired, frame(0, 0, 448, 208))
    }

    private func restoreWithoutGridRevision(_ document: DashboardDocument) throws -> DashboardDocument {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        json.removeValue(forKey: "layoutGridRevision")
        return try JSONDecoder().decode(DashboardDocument.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
