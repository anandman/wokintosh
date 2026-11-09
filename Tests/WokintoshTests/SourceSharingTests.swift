import AppKit
import EventKit
import XCTest
import WokintoshCore
@testable import Wokintosh

@MainActor final class SourceSharingTests:XCTestCase {
    func testSharingDefaultsOffAndPortableSetupsContainNoConsent() throws {
        let dir=directory();defer {try? FileManager.default.removeItem(at:dir)}
        let sharing=SourceSharing(directory:dir)
        XCTAssertFalse(sharing.options.enabled)
        let exported=try DashboardSetup.export(document:.defaultLayout,kind:.setup).encoded()
        XCTAssertFalse(String(decoding:exported,as:UTF8.self).contains("shareMusic"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent("shared-sources.json").path))
    }
    func testPrivatePublicationFiltersCalendarsAndImmediatelyRemovesDisabledSource() throws {
        let dir=directory();defer {try? FileManager.default.removeItem(at:dir)}
        let sharing=SourceSharing(directory:dir)
        let now=Date()
        let event=CalendarEntry(id:"selected",title:"Shared planning",startDate:now.addingTimeInterval(60),endDate:now.addingTimeInterval(3600),isAllDay:false,calendarID:"work")
        var hidden=event;hidden.id="hidden";hidden.calendarID="private";hidden.title="Private appointment"
        let calendar=CalendarInfo(events:[event,hidden],authorized:true,calendars:[CalendarDescriptor(id:"work",title:"Work",sourceTitle:"Local"),CalendarDescriptor(id:"private",title:"Personal",sourceTitle:"Local")])
        try sharing.setOptions(SourceSharingOptions(shareMusic:true,shareCalendar:true,calendarIDs:["work"]))
        try sharing.publish(music:NowPlayingInfo(title:"Blue Hour",updatedAt:now),musicAvailable:true,calendar:calendar,calendarReady:true,at:now)
        let url=dir.appendingPathComponent("shared-sources.json")
        var value=try publication(url)
        XCTAssertEqual(value.calendar?.events.map(\.id),["selected"])
        XCTAssertEqual(value.calendar?.calendars.map(\.id),["work"])
        let attrs=try FileManager.default.attributesOfItem(atPath:url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue,0o600)
        try sharing.setOptions(SourceSharingOptions(shareCalendar:true,calendarIDs:["work"]))
        value=try publication(url)
        XCTAssertNil(value.music)
        XCTAssertEqual(SourceSharing(directory:dir).options.calendarIDs,["work"])
        try sharing.setOptions(SourceSharingOptions())
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }
    func testRevokedOrPreviewSourcesCannotPublishRetainedPrivateData() throws {
        let dir=directory();defer {try? FileManager.default.removeItem(at:dir)}
        let sharing=SourceSharing(directory:dir)
        try sharing.setOptions(SourceSharingOptions(shareMusic:true,shareCalendar:true,calendarIDs:["work"]))
        let now=Date(),music=NowPlayingInfo(title:"Old track",updatedAt:Date())
        let calendar=CalendarInfo(events:[CalendarEntry(id:"one",title:"Old event",startDate:now,endDate:now.addingTimeInterval(3600),isAllDay:false,calendarID:"work")],authorized:true)
        try sharing.publish(music:music,musicAvailable:false,calendar:calendar,calendarReady:false,at:now)
        let value=try publication(dir.appendingPathComponent("shared-sources.json"))
        XCTAssertEqual(value.music?.available,false);XCTAssertEqual(value.music?.title,"")
        XCTAssertEqual(value.calendar?.available,false);XCTAssertTrue(value.calendar?.events.isEmpty == true)
        try sharing.publish(music:music,musicAvailable:true,calendar:calendar,calendarReady:true,preview:true,at:now)
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent("shared-sources.json").path))
    }
    func testRemoteOnlyCalendarDoesNotReadLocalEventsButSharingWorksWithoutWidget() async {
        let reader=SharingCalendarReader()
        let suite="wokintosh-sharing-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let native=NativeSources(defaults:defaults,calendarReader:reader,musicPermissionCheck:{false})
        var widget=Widget(kind:.calendar,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5));widget.hostID="minion"
        await native.refresh(document:DashboardDocument(widgets:[widget]))
        XCTAssertEqual(reader.reads,0)
        await native.refresh(document:DashboardDocument(widgets:[]),sharing:SourceSharingOptions(shareCalendar:true))
        XCTAssertEqual(reader.reads,1)
        XCTAssertEqual(reader.requests,0)
    }
    func testArtworkBecomesBoundedImageDataWithoutSourcePath() throws {
        let dir=directory();defer {try? FileManager.default.removeItem(at:dir)}
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let image=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:800,pixelsHigh:800,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let url=dir.appendingPathComponent("cover.png");try XCTUnwrap(image.representation(using:.png,properties:[:])).write(to:url)
        let data=try XCTUnwrap(SourceSharing.thumbnail(for:NowPlayingInfo(artworkURL:url)))
        XCTAssertLessThanOrEqual(data.count,SharedMusic.maximumArtworkBytes)
        let decoded=try XCTUnwrap(NSBitmapImageRep(data:data))
        XCTAssertLessThanOrEqual(decoded.pixelsWide,256);XCTAssertLessThanOrEqual(decoded.pixelsHigh,256)
    }
    func testRemoteArtworkRejectsOversizedPixelDimensionsBeforeDisplay() throws {
        let image=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:800,pixelsHigh:800,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let data=try XCTUnwrap(image.representation(using:.png,properties:[:]))
        XCTAssertNil(SharedSourceArtwork.image(from:data))
        XCTAssertNil(SharedSourceArtwork.image(from:Data([1,2,3])))
        let small=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:128,pixelsHigh:128,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        XCTAssertNotNil(SharedSourceArtwork.image(from:try XCTUnwrap(small.representation(using:.png,properties:[:]))))
    }
    private func directory()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("wokintosh-sharing-"+UUID().uuidString)}
    private func publication(_ url:URL)throws->SharedSourcesSnapshot {
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SharedSourcesSnapshot.self,from:Data(contentsOf:url))
    }
}
private final class SharingCalendarReader:CalendarReading,@unchecked Sendable {
    var reads=0;var requests=0
    func authorizationStatus()->EKAuthorizationStatus {.fullAccess}
    func read(authorizationRevision:UUID) async->CalendarInfo {reads+=1;return CalendarInfo(authorized:true)}
    func requestAccess() async->CalendarInfo {requests+=1;return CalendarInfo()}
}
