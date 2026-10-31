import XCTest
@testable import WokintoshCore

final class CalendarSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, calendarID: String = "work", start: Double = 60,
                       end: Double = 120, allDay: Bool = false) -> CalendarEntry {
        CalendarEntry(id: id, title: id, startDate: now.addingTimeInterval(start),
                      endDate: now.addingTimeInterval(end), isAllDay: allDay,
                      calendarID: calendarID, calendarTitle: "Events")
    }

    func testCalendarSelectionOccursBeforeTwelveEventLimit() {
        let irrelevant = (0..<20).map { event("other-\($0)", calendarID: "other", start: Double($0 + 1)) }
        let requested = (0..<15).map { event("wanted-\($0)", start: Double(100 + $0)) }
        let info = CalendarInfo(events: irrelevant + requested)
        let result = info.events(for: CalendarSelectionOptions(calendarIDs: ["work"], nextEventOnly: false), at: now)
        XCTAssertEqual(result.map(\.id), Array(requested.prefix(12)).map(\.id))
    }

    func testTimedOnlyNextSkipsAllDayBeforeApplyingSingleEventLimit() {
        let info = CalendarInfo(events: [event("all-day", start: -60, end: 86_400, allDay: true), event("timed")])
        XCTAssertEqual(info.events(for: CalendarSelectionOptions(includeAllDay: false), at: now).map(\.id), ["timed"])
    }

    func testEmptyCalendarSelectionShowsNoEventsWhileNilShowsAll() {
        let info = CalendarInfo(events: [event("event")])
        XCTAssertEqual(info.events(for: CalendarSelectionOptions(calendarIDs: []), at: now), [])
        XCTAssertEqual(info.events(for: CalendarSelectionOptions(), at: now).map(\.id), ["event"])
    }

    func testSelectionIncludesInProgressButRejectsEndedAndInvalidIntervals() {
        let info = CalendarInfo(events: [event("future", start: 60, end: 120),
                                        event("ended", start: -60, end: 0),
                                        event("in-progress", start: -60, end: 60),
                                        event("reversed", start: 120, end: 60),
                                        event("zero-duration", start: 60, end: 60),
                                        event("invalid", start: .nan, end: 60)])
        XCTAssertEqual(info.events(for: CalendarSelectionOptions(nextEventOnly: false), at: now).map(\.id), ["in-progress", "future"])
    }

    func testAllDayRemainsIncludedByDefaultAndResultsAreChronological() {
        let info = CalendarInfo(events: [event("later", start: 120, end: 180),
                                        event("all-day", start: -60, end: 86_400, allDay: true)])
        XCTAssertEqual(info.events(for: CalendarSelectionOptions(), at: now).map(\.id), ["all-day"])
        XCTAssertEqual(info.events(for: CalendarSelectionOptions(nextEventOnly: false), at: now).map(\.id), ["all-day", "later"])
    }

    func testDuplicateCalendarTitlesRemainDistinctAcrossAccounts() {
        let personal = CalendarDescriptor(id: "personal-events", title: "Events", sourceTitle: "Personal account")
        let work = CalendarDescriptor(id: "work-events", title: "Events", sourceTitle: "Work account")
        let info = CalendarInfo(events: [event("personal", calendarID: personal.id), event("work", calendarID: work.id)], calendars: [personal, work])
        XCTAssertNotEqual(info.calendars[0], info.calendars[1])
        XCTAssertEqual(info.calendars.map(\.sourceTitle), ["Personal account", "Work account"])
        XCTAssertEqual(info.events(for: CalendarSelectionOptions(calendarIDs: [work.id]), at: now).map(\.id), ["work"])
    }

    func testOptionsRoundTripAndDecodeDefaultsIncludingExplicitEmptySelection() throws {
        let options = CalendarSelectionOptions(calendarIDs: [], includeAllDay: false, nextEventOnly: false, excludedTitlePatterns: ["Placeholder"], collapseMirrors: false)
        XCTAssertEqual(try JSONDecoder().decode(CalendarSelectionOptions.self, from: JSONEncoder().encode(options)), options)
        XCTAssertEqual(try JSONDecoder().decode(CalendarSelectionOptions.self, from: Data("{}".utf8)), CalendarSelectionOptions())
        XCTAssertEqual(try JSONDecoder().decode(CalendarSelectionOptions.self, from: Data(#"{"calendarIDs":[]}"#.utf8)).calendarIDs, [])
    }

    func testLegacyInitializersKeepDefaultCalendarMetadata() {
        let entry = CalendarEntry(id: "old", title: "Old", startDate: now, endDate: now.addingTimeInterval(60), isAllDay: false)
        XCTAssertEqual(entry.calendarID, "")
        XCTAssertEqual(entry.calendarTitle, "")
        XCTAssertEqual(CalendarInfo(events: [entry], status: "Upcoming", authorized: true).calendars, [])
    }
    func testGenericMirrorCannotWinNextEventAheadOfOriginalTitle() {
        var mirror = event("mirror", calendarID: "mirror")
        mirror.title = "  BLOCKED   Time  "
        var original = event("original", calendarID: "work")
        original.title = "Zebra project review"
        let info = CalendarInfo(events: [mirror, original])
        XCTAssertEqual(info.events(for: CalendarSelectionOptions(), at: now).map(\.id), ["original"])
    }

    func testStandaloneBlockAndUnrelatedOverlapRemainVisible() {
        var block = event("standalone", start: 60, end: 180)
        block.title = "Busy"
        var overlap = event("overlap", start: 90, end: 150)
        overlap.title = "Customer call"
        var sameTime = event("same-time", start: 60, end: 180)
        sameTime.title = "Private appointment with doctor"
        let info = CalendarInfo(events: [overlap, block, sameTime])
        XCTAssertEqual(info.events(for: CalendarSelectionOptions(nextEventOnly: false), at: now).map(\.id), ["same-time", "overlap"])
        XCTAssertEqual(CalendarInfo(events: [block, overlap]).events(for: CalendarSelectionOptions(nextEventOnly: false), at: now).map(\.id), ["standalone", "overlap"])
    }

    func testUnselectedAlternativeDoesNotHideSelectedBlock() {
        var mirror = event("mirror", calendarID: "mirror")
        mirror.title = "Private appointment"
        let original = event("original", calendarID: "work")
        let info = CalendarInfo(events: [mirror, original])
        XCTAssertEqual(info.events(for: CalendarSelectionOptions(calendarIDs: ["mirror"]), at: now).map(\.id), ["mirror"])
    }

    func testExplicitTitleExclusionsArePlainCaseInsensitiveLinesBeforeNextLimit() throws {
        var placeholder = event("placeholder", start: 30, end: 90)
        placeholder.title = "[Private] BLOCKED entry"
        var regexLookalike = event("literal", start: 60, end: 120)
        regexLookalike.title = "Private entry"
        let options = try JSONDecoder().decode(CalendarSelectionOptions.self, from: Data(#"{"excludedTitlePatterns":["  [private]  \n  ","   "],"nextEventOnly":true}"#.utf8))
        XCTAssertEqual(CalendarInfo(events: [placeholder, regexLookalike]).events(for: options, at: now).map(\.id), ["literal"])
    }

    func testMirrorCollapseCanBeDisabledAndSortIsDeterministic() throws {
        var mirror = event("mirror")
        mirror.title = "Blocked Time"
        var original = event("original")
        original.title = "Zebra review"
        let options = try JSONDecoder().decode(CalendarSelectionOptions.self, from: Data(#"{"collapseMirrors":false,"nextEventOnly":false}"#.utf8))
        XCTAssertEqual(CalendarInfo(events: [original, mirror]).events(for: options, at: now).map(\.id), ["mirror", "original"])
        var a = event("a"); a.title = "Same title"
        var z = event("z"); z.title = "Same title"
        XCTAssertEqual(CalendarInfo(events: [z, a]).events(for: CalendarSelectionOptions(nextEventOnly: false), at: now).map(\.id), ["a", "z"])
    }

    func testDifferentRealEventsAtSameTimeAreNotCollapsed() {
        var first = event("first"); first.title = "Project review"
        var second = event("second"); second.title = "Customer call"
        XCTAssertEqual(CalendarInfo(events: [first, second]).events(for: CalendarSelectionOptions(nextEventOnly: false), at: now).map(\.id), ["second", "first"])
    }

}
