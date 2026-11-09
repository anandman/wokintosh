import EventKit
import XCTest
import WokintoshCore
@testable import Wokintosh

@MainActor final class NativeSourceRoutingTests:XCTestCase {
    func testRemoteMusicIsReadOnlyAndNeverUsesLocalTrackWhenMissingOrOffline() throws {
        let dir=directory();defer {try? FileManager.default.removeItem(at:dir)}
        let store=DashboardStore(dataDirectory:dir)
        store.native.music=NowPlayingInfo(title:"Private local track")
        var widget=Widget(kind:.music,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5))
        XCTAssertEqual(store.musicSource(for:widget).info.title,"Private local track")
        XCTAssertTrue(store.musicSource(for:widget).allowsPlayback)
        widget.hostID="remote"
        XCTAssertFalse(store.musicSource(for:widget).info.hasTrack)
        XCTAssertFalse(store.musicSource(for:widget).allowsPlayback)
        store.feeds["remote"]=FeedStatus(name:"Minion",snapshot:try snapshot(),error:"SSH disconnected")
        let remote=store.musicSource(for:widget)
        XCTAssertEqual(remote.info.title,"Blue Hour")
        XCTAssertFalse(remote.info.isPlaying)
        XCTAssertEqual(remote.source?.state,.offline)
    }
    func testCalendarUsesSelectedRemoteInventoryAndSwitchingSourceResetsOnlyCalendarIDs() throws {
        let dir=directory();defer {try? FileManager.default.removeItem(at:dir)}
        let store=DashboardStore(dataDirectory:dir)
        var widget=Widget(kind:.calendar,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5))
        widget.calendarOptions.calendarIDs=["local-private"];widget.calendarOptions.excludedTitlePatterns=["Canceled"]
        store.document.widgets=[widget]
        store.feeds["remote"]=FeedStatus(name:"Minion",snapshot:try snapshot())
        store.setNativeSource(widget.id,hostID:"remote")
        let selected=try XCTUnwrap(store.document.widgets.first)
        XCTAssertNil(selected.calendarOptions.calendarIDs)
        XCTAssertEqual(selected.calendarOptions.excludedTitlePatterns,["Canceled"])
        XCTAssertEqual(store.calendarSource(for:selected).info.calendars.map(\.id),["work"])
        XCTAssertEqual(store.calendarEvents(for:selected).map(\.id),["planning"])
        XCTAssertTrue(store.calendarSource(for:widget).info.calendars.isEmpty)
    }
    func testExplicitLocalCollectorIdentityRetainsLocalNativeSource() throws {
        let dir=directory();defer {try? FileManager.default.removeItem(at:dir)}
        let store=DashboardStore(dataDirectory:dir)
        store.feeds["local"]=FeedStatus(name:"This Mac",snapshot:try snapshot())
        store.native.music=NowPlayingInfo(title:"Local track")
        var widget=Widget(kind:.music,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5));widget.hostID="remote"
        XCTAssertTrue(store.musicSource(for:widget).allowsPlayback)
        XCTAssertEqual(store.musicSource(for:widget).info.title,"Local track")
    }
    func testRemotePlaybackCommandIsRejectedBeforeAnyLocalAction() async {
        let dir=directory();defer {try? FileManager.default.removeItem(at:dir)}
        let store=DashboardStore(dataDirectory:dir)
        var widget=Widget(kind:.music,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5));widget.hostID="remote"
        store.document.widgets=[widget]
        store.native.music=NowPlayingInfo(title:"Private local track")
        await store.performPlayback("playpause",for:widget.id)
        XCTAssertEqual(store.native.music.title,"Private local track")
    }
    private func directory()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("wokintosh-routing-"+UUID().uuidString)}
    private func snapshot() throws->Snapshot {
        let now=Date(),end=now.addingTimeInterval(3600)
        let format=ISO8601DateFormatter()
        let music:[String:Any]=["available":true,"updatedAt":format.string(from:now),"status":"Playing","title":"Blue Hour","artist":"Paper Satellites","album":"Evening","position":12,"duration":200,"isPlaying":true]
        let event:[String:Any]=["id":"planning","title":"Planning","startDate":format.string(from:now),"endDate":format.string(from:end),"isAllDay":false,"calendarID":"work","calendarTitle":"Work"]
        let calendar:[String:Any]=["available":true,"updatedAt":format.string(from:now),"status":"Upcoming","calendars":[["id":"work","title":"Work","sourceTitle":"Local"]],"events":[event]]
        let json:[String:Any]=["schemaVersion":1,"host":["id":"remote","name":"Minion","platform":"macos"],"generatedAt":format.string(from:now),"sessions":[],"system":[:],"sharedSources":["version":1,"generatedAt":format.string(from:now),"music":music,"calendar":calendar]]
        return try Snapshot.decode(JSONSerialization.data(withJSONObject:json))
    }
}
