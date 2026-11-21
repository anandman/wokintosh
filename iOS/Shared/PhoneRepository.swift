import Foundation
import WokintoshCore

protocol PhoneCredentialStore:Sendable {
    func load()throws->PhonePairing?
    func save(_ value:PhonePairing)throws
    func remove()throws
}
protocol PhoneFetching:Sendable {
    func fetch(_ pairing:PhonePairing)async throws->PublishedWidgetFeed
    func perform(_ command:AgentControlCommand,pairing:PhonePairing)async throws->PublishedWidgetFeed
}
extension PhoneFetching {
    func perform(_ command:AgentControlCommand,pairing:PhonePairing)async throws->PublishedWidgetFeed {throw AgentControlError.disabled}
}
extension PhoneFeedClient:PhoneFetching {}

struct PhoneSnapshot:Sendable {
    let feed:PublishedWidgetFeed?
    let state:PhoneConnectionState
    let lastFetchedAt:Date?
    let paired:Bool
    var actionMessage:String?=nil
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
    private var coordinator:PhoneRepositoryCoordinator {PhoneRepositoryCoordinator(directory:cache.directory)}
    func snapshot()throws->PhoneSnapshot {
        try coordinator.withLock {try snapshotLocked()}
    }
    private func snapshotLocked()throws->PhoneSnapshot {
        let status=cache.status()
        // Revocation stays effective even if a locked Keychain prevented deleting the credential.
        guard status.state != .authorizationRequired,try credentials.load() != nil else {
            if cache.load() != nil {try cache.requirePairing()}
            return PhoneSnapshot(feed:nil,state:status.state == .authorizationRequired ? .authorizationRequired : .unpaired,lastFetchedAt:nil,paired:false)
        }
        let feed=cache.load()
        return PhoneSnapshot(feed:feed,state:feed==nil ? .offline : status.state,lastFetchedAt:status.lastFetchedAt,paired:true,actionMessage:coordinator.actionMessage())
    }
    func pair(_ pairing:PhonePairing)throws {
        try coordinator.withLock {
            try coordinator.advanceGeneration()
            try cache.requirePairing()
            try credentials.save(pairing)
            try cache.clear()
        }
    }
    func unpair()throws {
        try coordinator.withLock {
            try coordinator.advanceGeneration()
            try cache.requirePairing()
            try credentials.remove()
            try cache.clear()
        }
    }
    func refresh()async throws->PhoneSnapshot {
        let request:(PhonePairing,UUID,UUID)?=try coordinator.withLock {
            guard !coordinator.actionInProgress(),cache.status().state != .authorizationRequired,let pairing=try credentials.load() else {return nil}
            return (pairing,try coordinator.generation(),try coordinator.beginRequest())
        }
        guard let (pairing,generation,requestID)=request else {return try snapshot()}
        let result:Result<PublishedWidgetFeed,Error>
        do {result = .success(try await client.fetch(pairing))}
        catch {result = .failure(error)}
        return try coordinator.withLock {
            // The app and extension share this generation and lock. Every response outcome
            // belongs to the captured pairing, including failures and pairing with the same code.
            // A newer app/extension request also supersedes every outcome of this one.
            guard try coordinator.generation()==generation,coordinator.latestRequest()==requestID,try credentials.load()==pairing,
                  cache.status().state != .authorizationRequired else {return try snapshotLocked()}
            switch result {
            case .success(let feed):try cache.store(feed,fetchedAt:Date())
            case .failure(is CancellationError):break
            case .failure(PhoneFetchError.unauthorized):
                try coordinator.advanceGeneration()
                try cache.requirePairing()
                try credentials.remove()
            case .failure:try cache.markUnavailable()
            }
            return try snapshotLocked()
        }
    }
    func perform(_ command:AgentControlCommand)async throws->PhoneSnapshot {
        let request=try coordinator.withLock { ()throws->(PhonePairing,UUID,UUID) in
            guard command.isValid,cache.status().state != .authorizationRequired,let pairing=try credentials.load(),
                  let feed=cache.load(),feed.publisherID==command.publisherID,feed.widgets.contains(where:{$0.id==command.widgetID}) else {throw AgentControlError.conflict}
            let generation=try coordinator.generation()
            try coordinator.beginAction(command.id)
            do {return (pairing,generation,try coordinator.beginRequest())}
            catch {coordinator.endAction(command.id);throw error}
        }
        let outcome:Result<PublishedWidgetFeed,Error>
        do {outcome = .success(try await client.perform(command,pairing:request.0))} catch {outcome = .failure(error)}
        return try coordinator.withLock {
            defer {coordinator.endAction(command.id)}
            guard try coordinator.generation()==request.1,coordinator.latestRequest()==request.2,
                  try credentials.load()==request.0,cache.status().state != .authorizationRequired else {throw AgentControlError.unconfirmed}
            switch outcome {
            case .success(let feed):
                guard feed.publisherID==command.publisherID else {throw AgentControlError.unconfirmed}
                try cache.store(feed,fetchedAt:Date());try coordinator.setActionMessage(nil)
                return try snapshotLocked()
            case .failure(let error):
                if error as? PhoneFetchError == .unauthorized {
                    try coordinator.advanceGeneration();try cache.requirePairing();try credentials.remove()
                } else {try coordinator.setActionMessage(error.localizedDescription)}
                throw error
            }
        }
    }

}

enum PhoneStorageError:Error,LocalizedError {
    case notConfigured,keychain
    var errorDescription:String? {
        switch self {
        case .notConfigured:return "Widget sharing is not available in this build. Reinstall Wokintosh with its app and widget sharing capabilities enabled."
        case .keychain:return "Wokintosh could not access its saved pairing. Unlock your device and try again."
        }
    }
}
