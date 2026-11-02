import Combine
import EventKit
import XCTest
import WokintoshCore
@testable import Wokintosh

@MainActor
final class CalendarConnectionTests: XCTestCase {
    // Removing NativeSources' synchronous grant preflight must fail this regression.
    func testStartupRecognizesExistingGrantWithoutWidgetOrEventRead() async {
        let reader = ControlledCalendarReader(status: .fullAccess)
        let native = makeSources(reader)
        XCTAssertTrue(native.calendar.authorized)
        XCTAssertTrue(native.calendarLoading)
        XCTAssertTrue(native.calendar.events.isEmpty)
        var document = DashboardDocument.defaultLayout
        document.widgets = []
        await native.refresh(document: document)
        XCTAssertTrue(native.calendar.authorized)
        XCTAssertEqual(reader.readCount, 0)
        XCTAssertEqual(reader.requestCount, 0)
    }

    // A grant changed outside the app must self-correct even when event polling is not scheduled.
    func testAutomaticRefreshRecognizesNewGrantWithNoCalendarWidget() async {
        let reader = ControlledCalendarReader(status: .denied)
        let native = makeSources(reader)
        reader.status = .fullAccess
        var document = DashboardDocument.defaultLayout
        document.widgets = []
        await native.refresh(document: document)
        XCTAssertTrue(native.calendar.authorized)
        XCTAssertTrue(native.calendarLoading)
        XCTAssertEqual(reader.readCount, 0)
        XCTAssertEqual(reader.requestCount, 0)
    }

    // A permission change during EventKit work must be checked again before data is displayed.
    func testReadCompletionChecksRevocationWithoutAnotherRefresh() async {
        let reader = ControlledCalendarReader(status: .fullAccess)
        let native = makeSources(reader)
        let task = Task { await native.refreshConnectionStatus() }
        await fulfillment(of: [reader.readStarted], timeout: 2)
        reader.status = .denied
        reader.completeReads(with: eventInfo("stale"))
        await task.value
        XCTAssertFalse(native.calendar.authorized)
        XCTAssertTrue(native.calendar.events.isEmpty)
        XCTAssertTrue(native.calendar.calendars.isEmpty)
    }

    // Joining Calendar publication behind either delayed dependency must fail this regression.
    func testRefreshPublishesGrantAndEventsBeforeMusicPreflightFinishes() async {
        let reader = ControlledCalendarReader(status: .denied)
        let music = DeferredMusicPermission()
        let native = makeSources(reader, musicPermissionCheck: { await music.check() })
        reader.status = .fullAccess
        let published = expectation(description: "Calendar data published while Music remains pending")
        let subscription = native.$calendar.sink { if $0.events.map(\.id) == ["fresh"] { published.fulfill() } }
        let task = Task { await native.refreshConnectionStatus() }
        await fulfillment(of: [reader.readStarted], timeout: 2)
        XCTAssertTrue(native.calendar.authorized)
        XCTAssertTrue(native.calendarLoading)
        reader.completeReads(with: eventInfo("fresh"))
        await fulfillment(of: [published], timeout: 2)
        XCTAssertTrue(native.calendar.authorized)
        XCTAssertFalse(native.calendarLoading)
        await music.finish()
        await task.value
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(reader.requestCount, 0)
    }

    // Applying an in-flight granted event result after revocation must fail this regression.
    func testRevocationClearsEventsAndRejectsInFlightGrantedResult() async {
        let reader = ControlledCalendarReader(status: .fullAccess)
        let native = makeSources(reader)
        let first = Task { await native.refreshConnectionStatus() }
        await fulfillment(of: [reader.readStarted], timeout: 2)
        reader.completeReads(with: eventInfo("old"))
        await first.value
        XCTAssertEqual(native.calendar.events.map(\.id), ["old"])
        reader.readStarted = expectation(description: "second Calendar read")
        let pending = Task { await native.refreshConnectionStatus() }
        await fulfillment(of: [reader.readStarted], timeout: 2)
        reader.status = .denied
        var document = DashboardDocument.defaultLayout
        document.widgets = []
        await native.refresh(document: document)
        XCTAssertFalse(native.calendar.authorized)
        XCTAssertTrue(native.calendar.events.isEmpty)
        XCTAssertTrue(native.calendar.calendars.isEmpty)
        reader.completeReads(with: eventInfo("stale"))
        await pending.value
        XCTAssertFalse(native.calendar.authorized)
        XCTAssertTrue(native.calendar.events.isEmpty)
        XCTAssertFalse(native.calendarLoading)
        XCTAssertEqual(reader.requestCount, 0)
    }

    // Taking authorization from an old event payload must fail this regression.
    func testStaleUnauthorizedReadCannotDisconnectCurrentGrant() async {
        let reader = ControlledCalendarReader(status: .fullAccess)
        let native = makeSources(reader)
        let task = Task { await native.refreshConnectionStatus() }
        await fulfillment(of: [reader.readStarted], timeout: 2)
        reader.completeReads(with: CalendarInfo())
        await task.value
        XCTAssertTrue(native.calendar.authorized)
        XCTAssertFalse(native.calendarLoading)
        XCTAssertTrue(native.calendar.events.isEmpty)
        XCTAssertEqual(reader.requestCount, 0)
    }

    // Rejecting old data without scheduling a new-generation read leaves no-widget Settings stuck.
    func testRegrantDuringReadAutomaticallyLoadsFreshGenerationWithoutWidget() async {
        let reader = ControlledCalendarReader(status: .fullAccess)
        let native = makeSources(reader)
        let task = Task { await native.refreshConnectionStatus() }
        await fulfillment(of: [reader.readStarted], timeout: 2)
        reader.status = .denied
        native.refreshCalendarAuthorization()
        reader.status = .fullAccess
        native.refreshCalendarAuthorization()
        var document = DashboardDocument.defaultLayout
        document.widgets = []
        await native.refresh(document: document)
        reader.readStarted = expectation(description: "new grant reads fresh data automatically")
        reader.completeReads(with: eventInfo("stale"))
        await fulfillment(of: [reader.readStarted], timeout: 2)
        XCTAssertTrue(native.calendar.events.isEmpty)
        XCTAssertTrue(native.calendarLoading)
        XCTAssertEqual(reader.readCount, 2)
        if reader.readRevisions.count == 2 {
            XCTAssertNotEqual(reader.readRevisions[0], reader.readRevisions[1])
        }
        reader.completeReads(with: eventInfo("fresh"))
        await task.value
        XCTAssertEqual(native.calendar.events.map(\.id), ["fresh"])
        XCTAssertTrue(native.calendar.authorized)
        XCTAssertFalse(native.calendarLoading)
        XCTAssertEqual(reader.requestCount, 0)
    }

    // Explicit Connect must retain its request action and display the first granted payload.
    func testExplicitConnectAcceptsFirstGrantAndItsEvents() async {
        let reader = ControlledCalendarReader(status: .notDetermined, requestStatus: .fullAccess, requestResult: eventInfo("first-grant"))
        let native = makeSources(reader)
        await native.requestCalendarAccess()
        XCTAssertTrue(native.calendar.authorized)
        XCTAssertEqual(native.calendar.events.map(\.id), ["first-grant"])
        XCTAssertEqual(reader.requestCount, 1)
        XCTAssertEqual(reader.readCount, 0)
    }

    // Rejecting a system consent request must leave the source disconnected and event data empty.
    func testExplicitConnectDeniedRemainsDisconnected() async {
        let reader = ControlledCalendarReader(status: .notDetermined, requestStatus: .denied)
        let native = makeSources(reader)
        await native.requestCalendarAccess()
        XCTAssertFalse(native.calendar.authorized)
        XCTAssertTrue(native.calendar.events.isEmpty)
        XCTAssertFalse(native.calendarLoading)
        XCTAssertEqual(reader.requestCount, 1)
    }

    // Dropping operational errors hides the reason an explicit Connect failed before any grant.
    func testExplicitConnectPreservesFailureWhileAuthorizationRemainsUndetermined() async {
        var failed = eventInfo("must-not-leak")
        failed.authorized = false
        failed.status = "Calendar access unavailable: service interrupted"
        let reader = ControlledCalendarReader(status: .notDetermined, requestResult: failed)
        let native = makeSources(reader)
        await native.requestCalendarAccess()
        XCTAssertFalse(native.calendar.authorized)
        XCTAssertEqual(native.calendar.status, "Calendar access unavailable: service interrupted")
        XCTAssertTrue(native.calendar.events.isEmpty)
        XCTAssertTrue(native.calendar.calendars.isEmpty)
        XCTAssertEqual(reader.requestCount, 1)
    }

    // Any implicit request during initial/status/document refresh must fail this regression.
    func testDeniedAndUndeterminedRefreshNeverRequestAccess() async {
        for status: EKAuthorizationStatus in [.denied, .notDetermined, .restricted, .writeOnly] {
            let reader = ControlledCalendarReader(status: status)
            let native = makeSources(reader)
            await native.refreshConnectionStatus()
            var document = DashboardDocument.defaultLayout
            document.widgets = [Widget(kind: .calendar, frame: .init(x: 0, y: 0, width: 0.5, height: 0.5))]
            await native.refresh(document: document)
            XCTAssertFalse(native.calendar.authorized)
            XCTAssertTrue(native.calendar.events.isEmpty)
            XCTAssertEqual(reader.requestCount, 0)
            XCTAssertEqual(reader.readCount, 0)
        }
    }

    // Reusing Connect when macOS already grants access must never request consent again.
    func testConnectWithExistingGrantOnlyRefreshesData() async {
        let reader = ControlledCalendarReader(status: .fullAccess)
        let native = makeSources(reader)
        let task = Task { await native.requestCalendarAccess() }
        await fulfillment(of: [reader.readStarted], timeout: 2)
        reader.completeReads(with: eventInfo("fresh"))
        await task.value
        XCTAssertTrue(native.calendar.authorized)
        XCTAssertEqual(native.calendar.events.map(\.id), ["fresh"])
        XCTAssertEqual(reader.requestCount, 0)
    }

    private func makeSources(_ reader: ControlledCalendarReader,
                             musicPermissionCheck: @escaping @Sendable () async -> Bool? = { nil }) -> NativeSources {
        let defaults = UserDefaults(suiteName: "Wokintosh.CalendarConnectionTests.\(UUID().uuidString)")!
        return NativeSources(defaults: defaults, calendarReader: reader, musicPermissionCheck: musicPermissionCheck)
    }

    private func eventInfo(_ id: String) -> CalendarInfo {
        CalendarInfo(events: [.init(id: id, title: "Meeting", startDate: Date(timeIntervalSince1970: 2_000_000_000),
                                    endDate: Date(timeIntervalSince1970: 2_000_003_600), isAllDay: false,
                                    calendarID: "work", calendarTitle: "Work")],
                     status: "Upcoming · next 7 days", authorized: true,
                     calendars: [.init(id: "work", title: "Work", sourceTitle: "Test")])
    }
}

private final class ControlledCalendarReader: CalendarReading, @unchecked Sendable {
    private let lock = NSLock()
    private var currentStatus: EKAuthorizationStatus
    private var continuations: [CheckedContinuation<CalendarInfo, Never>] = []
    private let requestStatus: EKAuthorizationStatus?
    private let requestResult: CalendarInfo
    private var revisions: [UUID] = []
    private var reads = 0
    private var requests = 0
    var readStarted = XCTestExpectation(description: "Calendar read")
    init(status: EKAuthorizationStatus, requestStatus: EKAuthorizationStatus? = nil, requestResult: CalendarInfo = CalendarInfo()) {
        currentStatus = status
        self.requestStatus = requestStatus
        self.requestResult = requestResult
    }
    var status: EKAuthorizationStatus {
        get { lock.withLock { currentStatus } }
        set { lock.withLock { currentStatus = newValue } }
    }
    var readCount: Int { lock.withLock { reads } }
    var requestCount: Int { lock.withLock { requests } }
    var readRevisions: [UUID] { lock.withLock { revisions } }
    func authorizationStatus() -> EKAuthorizationStatus { status }
    func read(authorizationRevision: UUID) async -> CalendarInfo {
        if status != .fullAccess {
            lock.withLock { reads += 1 }
            return CalendarInfo()
        }
        return await withCheckedContinuation { continuation in
            lock.withLock { reads += 1; revisions.append(authorizationRevision); continuations.append(continuation) }
            readStarted.fulfill()
        }
    }
    func requestAccess() async -> CalendarInfo {
        lock.withLock {
            requests += 1
            if let requestStatus { currentStatus = requestStatus }
        }
        return requestResult
    }
    func completeReads(with info: CalendarInfo) {
        let pending = lock.withLock { let pending = continuations; continuations = []; return pending }
        for continuation in pending { continuation.resume(returning: info) }
    }
}

private actor DeferredMusicPermission {
    private var continuation: CheckedContinuation<Bool?, Never>?
    private var finished = false
    func check() async -> Bool? {
        if finished { return nil }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        finished = true
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
