import XCTest
@testable import WokintoshCore

final class SharedSourcesTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    func testOldAndMalformedOptionalSourcesKeepBaselineSnapshotUsable() throws {
        for extra in ["",",\"sharedSources\":{\"version\":1,\"generatedAt\":\"bad\"}",",\"sharedSources\":{\"version\":99,\"generatedAt\":\"2027-01-15T08:00:00Z\"}"] {
            let json="{\"schemaVersion\":1,\"host\":{\"id\":\"host\",\"name\":\"Mac\",\"platform\":\"macos\"},\"generatedAt\":\"2027-01-15T08:00:00Z\",\"sessions\":[],\"system\":{\"cpuPercent\":28}"+extra+"}"
            let snapshot=try Snapshot.decode(Data(json.utf8))
            XCTAssertEqual(snapshot.system.cpuPercent,28)
            XCTAssertNil(snapshot.sharedSources)
        }
    }
    func testWireRoundTripCarriesArtworkAndSelectedCalendarWithoutLocalPaths() throws {
        let event=CalendarEntry(id:"one",title:"Planning",startDate:now.addingTimeInterval(60),endDate:now.addingTimeInterval(3600),isAllDay:false,calendarID:"selected",calendarTitle:"Work")
        let other=CalendarEntry(id:"private",title:"Not shared",startDate:now,endDate:now.addingTimeInterval(120),isAllDay:false,calendarID:"other",calendarTitle:"Personal")
        let info=CalendarInfo(events:[event,other],authorized:true,calendars:[CalendarDescriptor(id:"selected",title:"Work",sourceTitle:"Local"),CalendarDescriptor(id:"other",title:"Personal",sourceTitle:"Local")])
        let calendar=SharedCalendar(info:info,available:true,calendarIDs:["selected"],at:now)
        let music=SharedMusic(info:NowPlayingInfo(title:"Blue Hour",updatedAt:now,artworkURL:URL(fileURLWithPath:"/private/music.jpg")),available:true,at:now,artwork:Data([1,2,3]))
        let value=SharedSourcesSnapshot(generatedAt:now,music:music,calendar:calendar)
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        var snapshot=makeSnapshot(id:"remote",shared:value)
        let data=try encoder.encode(snapshot)
        let decoded=try Snapshot.decode(data)
        XCTAssertEqual(decoded.sharedSources?.calendar?.events.map(\.id),["one"])
        XCTAssertEqual(decoded.sharedSources?.calendar?.calendars.map(\.id),["selected"])
        XCTAssertEqual(decoded.sharedSources?.music?.artworkBase64,Data([1,2,3]))
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("/private/music"))
        snapshot.sharedSources?.music?.duration = .infinity
        XCTAssertThrowsError(try encoder.encode(snapshot))
    }
    func testRemoteSelectionNeverFallsBackToLocalAndMissingPublicationExplainsSetup() {
        let local=FeedStatus(name:"This Mac",snapshot:makeSnapshot(id:"local",shared:publication(title:"Local private track")))
        let missing=NativeSourcePresentation.music(hostID:"remote",feeds:["local":local],at:now)
        XCTAssertFalse(missing.info.hasTrack)
        XCTAssertEqual(missing.source?.state,.offline)
        let remote=FeedStatus(name:"Minion",snapshot:makeSnapshot(id:"remote",shared:nil))
        let result=NativeSourcePresentation.music(hostID:"remote",feeds:["local":local,"r":remote],at:now)
        XCTAssertFalse(result.info.hasTrack)
        XCTAssertEqual(result.source?.state,.notShared)
        XCTAssertTrue(result.info.status.contains("Minion"))
    }
    func testFreshStaleOfflineAndFutureMusicFreezeAtObservedPosition() {
        for (age,error,expected) in [(0.0,nil,RemoteSourceState.ready),(91.0,nil,.stale),(0.0,"SSH unavailable",.offline),(-31.0,nil,.stale)] {
            var shared=publication(title:"Remote track")
            shared.generatedAt=now.addingTimeInterval(-age)
            shared.music?.updatedAt=shared.generatedAt
            let result=NativeSourcePresentation.music(hostID:"remote",feeds:["r":FeedStatus(name:"Minion",snapshot:makeSnapshot(id:"remote",shared:shared),error:error)],at:now)
            XCTAssertEqual(result.source?.state,expected)
            XCTAssertEqual(result.info.title,"Remote track")
            XCTAssertEqual(result.info.isPlaying,expected == .ready)
            XCTAssertEqual(result.info.position,12)
        }
    }
    func testCalendarPublicationIsExplicitBoundedAndUnavailableClearsEvents() {
        let events=(0..<300).map { CalendarEntry(id:"event\($0)",title:"Planning",startDate:now.addingTimeInterval(Double($0+1)),endDate:now.addingTimeInterval(3600),isAllDay:false,calendarID:"work") }
        let info=CalendarInfo(events:events,authorized:true,calendars:[CalendarDescriptor(id:"work",title:"Work",sourceTitle:"Local")])
        XCTAssertTrue(SharedCalendar(info:info,available:true,calendarIDs:[],at:now).events.isEmpty)
        XCTAssertEqual(SharedCalendar(info:info,available:true,calendarIDs:["work"],at:now).events.count,256)
        let revoked=SharedCalendar(info:info,available:false,calendarIDs:["work"],at:now)
        XCTAssertTrue(revoked.events.isEmpty)
        XCTAssertTrue(revoked.calendars.isEmpty)
    }
    func testRemoteCalendarFiltersApplyOnlyToChosenSourceAndUnavailableClearsPayload() {
        let entry=CalendarEntry(id:"remote",title:"Remote Planning",startDate:now.addingTimeInterval(60),endDate:now.addingTimeInterval(3600),isAllDay:false,calendarID:"work")
        let shared=SharedSourcesSnapshot(generatedAt:now,calendar:SharedCalendar(info:CalendarInfo(events:[entry],authorized:true),available:true,calendarIDs:["work"],at:now))
        let result=NativeSourcePresentation.calendar(hostID:"remote",feeds:["r":FeedStatus(name:"Minion",snapshot:makeSnapshot(id:"remote",shared:shared))],at:now)
        XCTAssertEqual(result.info.events(for:CalendarSelectionOptions(),at:now).map(\.id),["remote"])
        XCTAssertTrue(result.info.events(for:CalendarSelectionOptions(calendarIDs:["local-id"]),at:now).isEmpty)
        let off=SharedMusic(info:NowPlayingInfo(title:"Must not leave",updatedAt:now),available:false,at:now)
        XCTAssertTrue(off.title.isEmpty)
        XCTAssertNil(off.artworkBase64)
    }
    func testRemoteWarningReservesTheSameCalendarCapacityAsItsContent() {
        let source=RemoteSourceStatus(name:"Minion",state:.offline,updatedAt:now)
        let layout=NativeWidgetSourceLayout(height:98.5,textScale:1,source:source)
        XCTAssertEqual(layout.contentHeight+layout.statusHeight,98.5,accuracy:0.01)
        let calendar=CalendarWidgetLayout(width:544,height:layout.contentHeight,textScale:1,eventCount:8,nextEventOnly:false)
        XCTAssertEqual(calendar.visibleCount,1)
        let minimum=NativeWidgetSourceLayout(height:59.16,textScale:1.6,source:source)
        XCTAssertFalse(minimum.showsContent)
    }
    private func publication(title:String)->SharedSourcesSnapshot {
        SharedSourcesSnapshot(generatedAt:now,music:SharedMusic(info:NowPlayingInfo(title:title,isPlaying:true,position:12,duration:200,updatedAt:now),available:true,at:now))
    }
    private func makeSnapshot(id:String,shared:SharedSourcesSnapshot?)->Snapshot {
        Snapshot(schemaVersion:1,host:HostInfo(id:id,name:id,platform:"macos"),generatedAt:now,sessions:[],system:SystemReading(),sharedSources:shared)
    }
}
