import Foundation

public enum PhoneConnectionState:String,Codable,Sendable {case unpaired,current,offline,authorizationRequired}
public struct PhoneCacheStatus:Codable,Equatable,Sendable {
    public let state:PhoneConnectionState
    public let lastFetchedAt:Date?
    public init(state:PhoneConnectionState,lastFetchedAt:Date?=nil) {self.state=state;self.lastFetchedAt=lastFetchedAt}
}

public struct PhoneSnapshotCache:Sendable {
    public let directory:URL
    public init(directory:URL) {self.directory=directory}
    private var feedURL:URL {directory.appendingPathComponent("feed.json")}
    private var statusURL:URL {directory.appendingPathComponent("connection.json")}
    public func load()->PublishedWidgetFeed? {
        guard let data=boundedRead(feedURL,limit:PublishedWidgetFeed.maximumBytes) else {return nil}
        return try? PublishedWidgetFeed.decode(data)
    }
    public func status()->PhoneCacheStatus {
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        guard let data=boundedRead(statusURL,limit:4096),let status=try? decoder.decode(PhoneCacheStatus.self,from:data) else {return PhoneCacheStatus(state:.unpaired)}
        return status
    }
    public func store(_ feed:PublishedWidgetFeed,fetchedAt:Date)throws {
        try writePrivate(feed.encoded(),to:feedURL)
        try writeStatus(PhoneCacheStatus(state:.current,lastFetchedAt:fetchedAt))
    }
    public func markUnavailable()throws {
        try writeStatus(PhoneCacheStatus(state:.offline,lastFetchedAt:status().lastFetchedAt))
    }
    public func requirePairing()throws {
        if FileManager.default.fileExists(atPath:feedURL.path) {try FileManager.default.removeItem(at:feedURL)}
        try writeStatus(PhoneCacheStatus(state:.authorizationRequired))
    }
    public func clear()throws {
        for file in [feedURL,statusURL] where FileManager.default.fileExists(atPath:file.path) {try FileManager.default.removeItem(at:file)}
    }
    private func writeStatus(_ status:PhoneCacheStatus)throws {
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        try writePrivate(encoder.encode(status),to:statusURL)
    }
    private func boundedRead(_ url:URL,limit:Int)->Data? {
        guard let handle=try? FileHandle(forReadingFrom:url) else {return nil}
        defer {try? handle.close()}
        guard let data=try? handle.read(upToCount:limit+1),data.count<=limit else {return nil}
        return data
    }
    private func writePrivate(_ data:Data,to url:URL)throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try data.write(to:url,options:.atomic)
        var attributes:[FileAttributeKey:Any]=[.posixPermissions:0o600]
        #if os(iOS)
        attributes[.protectionKey]=FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.setAttributes(attributes,ofItemAtPath:url.path)
    }
}
