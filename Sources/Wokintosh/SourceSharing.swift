import AppKit
import Combine
import ImageIO
import WokintoshCore

/// Native data leaves this Mac only through this explicitly enabled, private cache.
@MainActor final class SourceSharing:ObservableObject {
    @Published private(set) var options:SourceSharingOptions
    @Published private(set) var status="Not sharing"
    private let directory:URL
    private var publication:SharedSourcesSnapshot?
    private var cacheURL:URL {directory.appendingPathComponent("shared-sources.json")}
    private var settingsURL:URL {directory.appendingPathComponent("sharing-settings.json")}
    init(directory:URL) {
        self.directory=directory
        if let size=(try? FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent("sharing-settings.json").path)[.size]) as? NSNumber,
           size.intValue<=64*1024,let data=try? Data(contentsOf:directory.appendingPathComponent("sharing-settings.json")),
           let saved=try? JSONDecoder().decode(SourceSharingOptions.self,from:data) {options=Self.bounded(saved)}
        else {options=SourceSharingOptions()}
        if !options.enabled {try? FileManager.default.removeItem(at:directory.appendingPathComponent("shared-sources.json"))}
        else {status="Waiting for source refresh"}
    }
    func setOptions(_ value:SourceSharingOptions) throws {
        let next=Self.bounded(value)
        guard next != options else {return}
        // Revoke the old publication before persisting or doing any work that can fail.
        try removeCache()
        options=next
        do {
            try writePrivate(try JSONEncoder().encode(next),to:settingsURL)
            guard next.enabled else {publication=nil;status="Not sharing";return}
            if var retained=publication {
                if !next.shareMusic {retained.music=nil}
                if !next.shareCalendar {retained.calendar=nil}
                else if var calendar=retained.calendar {
                    let ids=Set(next.calendarIDs)
                    calendar.events.removeAll{!ids.contains($0.calendarID)}
                    calendar.calendars.removeAll{!ids.contains($0.id)}
                    retained.calendar=calendar
                }
                try writePublication(retained)
            } else {status="Waiting for source refresh"}
        } catch {status="Could not save sharing settings: \(error.localizedDescription)";throw error}
    }
    func publish(music:NowPlayingInfo,musicAvailable:Bool,calendar:CalendarInfo,calendarReady:Bool,preview:Bool=false,at now:Date=Date()) throws {
        guard options.enabled && !preview else {
            try removeCache();publication=nil;status=preview && options.enabled ? "Sharing paused in Preview" : "Not sharing";return
        }
        let musicPayload=options.shareMusic ? SharedMusic(info:music,available:musicAvailable,at:now,artwork:musicAvailable ? Self.thumbnail(for:music) : nil) : nil
        var calendarPayload=options.shareCalendar ? SharedCalendar(info:calendar,available:calendarReady && calendar.authorized,calendarIDs:options.calendarIDs,at:now) : nil
        if options.shareCalendar && options.calendarIDs.isEmpty {calendarPayload?.status="No calendars selected for sharing"}
        do {try writePublication(SharedSourcesSnapshot(generatedAt:now,music:musicPayload,calendar:calendarPayload))}
        catch {try? removeCache();status="Could not share sources: \(error.localizedDescription)";throw error}
    }
    static func thumbnail(for info:NowPlayingInfo)->Data? {
        guard let url=info.artworkURL,url.isFileURL,
              let size=(try? FileManager.default.attributesOfItem(atPath:url.path)[.size]) as? NSNumber,size.intValue<=8*1024*1024,
              let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                    kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:256,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {return nil}
        let data=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(data,"public.jpeg" as CFString,1,nil) else {return nil}
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination),data.length<=SharedMusic.maximumArtworkBytes else {return nil}
        return data as Data
    }
    private static func bounded(_ value:SourceSharingOptions)->SourceSharingOptions {
        SourceSharingOptions(shareMusic:value.shareMusic,shareCalendar:value.shareCalendar,
                             calendarIDs:Array(Set(value.calendarIDs.filter{!$0.isEmpty && $0.count<=512})).sorted().prefix(128).map{$0})
    }
    private func writePublication(_ value:SharedSourcesSnapshot) throws {
        var value=value
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        var data=try encoder.encode(value)
        // Unusually long Unicode metadata must still obey the collector's 1MiB read bound.
        while data.count>1024*1024 && !(value.calendar?.events.isEmpty ?? true) {
            let count=value.calendar!.events.count
            value.calendar?.events.removeLast(max(1,count/2))
            data=try encoder.encode(value)
        }
        guard data.count<=1024*1024 else {throw CocoaError(.fileWriteOutOfSpace)}
        try writePrivate(data,to:cacheURL)
        publication=value
        status="Sharing while Wokintosh is running"
    }
    private func removeCache() throws {
        if FileManager.default.fileExists(atPath:cacheURL.path) {try FileManager.default.removeItem(at:cacheURL)}
    }
    private func writePrivate(_ data:Data,to url:URL) throws {
        let manager=FileManager.default
        try manager.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let temporary=directory.appendingPathComponent(".wokintosh-sharing-"+UUID().uuidString+".tmp")
        guard manager.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw CocoaError(.fileWriteUnknown)}
        defer {try? manager.removeItem(at:temporary)}
        let file=try FileHandle(forWritingTo:temporary)
        do {try file.write(contentsOf:data);try file.close()}
        catch {try? file.close();throw error}
        guard rename(temporary.path,url.path) == 0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
    }
}
