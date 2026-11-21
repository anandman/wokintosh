import Foundation
import WokintoshCore

protocol PhoneCredentialStore:Sendable {
    func load()throws->PhonePairing?
    func save(_ value:PhonePairing)throws
    func remove()throws
}
protocol PhoneFetching:Sendable {
    func fetch(_ pairing:PhonePairing)async throws->PublishedWidgetFeed
}
extension PhoneFeedClient:PhoneFetching {}

struct PhoneSnapshot:Sendable {
    let feed:PublishedWidgetFeed?
    let state:PhoneConnectionState
    let lastFetchedAt:Date?
    let paired:Bool
    static let empty=PhoneSnapshot(feed:nil,state:.unpaired,lastFetchedAt:nil,paired:false)
}

struct PhoneRepository:Sendable {
    let cache:PhoneSnapshotCache
    let credentials:any PhoneCredentialStore
    let client:any PhoneFetching
    static func live()throws->PhoneRepository {
        guard let directory=FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:"group.dev.wokintosh.phone.shared") else {throw PhoneStorageError.notConfigured}
        return PhoneRepository(cache:PhoneSnapshotCache(directory:directory.appendingPathComponent("PublishedWidgets",isDirectory:true)),
                               credentials:try KeychainPhoneCredentials(),client:PhoneFeedClient())
    }
    func snapshot()throws->PhoneSnapshot {
        let status=cache.status()
        guard try credentials.load() != nil else {
            if cache.load() != nil {try cache.clear()}
            return PhoneSnapshot(feed:nil,state:status.state == .authorizationRequired ? .authorizationRequired : .unpaired,lastFetchedAt:nil,paired:false)
        }
        let feed=cache.load()
        return PhoneSnapshot(feed:feed,state:feed==nil ? .offline : status.state,lastFetchedAt:status.lastFetchedAt,paired:true)
    }
    func pair(_ pairing:PhonePairing)throws {
        try cache.clear();try credentials.save(pairing)
    }
    func unpair()throws {
        try cache.requirePairing()
        try credentials.remove()
        try cache.clear()
    }
    func refresh()async throws->PhoneSnapshot {
        guard let pairing=try credentials.load() else {return try snapshot()}
        do {
            let feed=try await client.fetch(pairing)
            // An old in-flight response cannot replace a newly paired publisher.
            guard try credentials.load()==pairing else {return try snapshot()}
            try cache.store(feed,fetchedAt:Date())
        } catch is CancellationError {return try snapshot()}
        catch PhoneFetchError.unauthorized {
            try cache.requirePairing();try credentials.remove()
        } catch {try cache.markUnavailable()}
        return try snapshot()
    }
}

enum PhoneStorageError:Error,LocalizedError {
    case notConfigured,keychain
    var errorDescription:String? {
        switch self {
        case .notConfigured:return "Phone sharing is not available in this build. Reinstall Wokintosh with its app and widget sharing capabilities enabled."
        case .keychain:return "Wokintosh could not access its saved phone pairing. Unlock your iPhone and try again."
        }
    }
}
