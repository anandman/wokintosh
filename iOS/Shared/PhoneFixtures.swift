import Foundation
import WokintoshCore

#if DEBUG
private final class PreviewPhoneCredentials:PhoneCredentialStore,@unchecked Sendable {
    var pairing:PhonePairing?
    func load()throws->PhonePairing? {pairing}
    func save(_ value:PhonePairing)throws {pairing=value}
    func remove()throws {pairing=nil}
}
#endif
enum PhoneFixtures {
    #if DEBUG
    static func repository()throws->PhoneRepository {
        let cache=PhoneSnapshotCache(directory:FileManager.default.temporaryDirectory.appendingPathComponent("wokintosh-sample-data"))
        let credentials=PreviewPhoneCredentials()
        credentials.pairing=try PhonePairing(endpoint:"https://sample.example.ts.net:9443/wokintosh/v1/widgets",token:String(repeating:"A",count:43))
        try cache.store(feed(),fetchedAt:Date())
        return PhoneRepository(cache:cache,credentials:credentials,client:PhoneFeedClient())
    }
    #endif
    static func feed(at now:Date=Date())->PublishedWidgetFeed {
        let values:[(String,String,String,AgentState)]=[("Review database migration","Build Mac","codex",.needsAttention),("Polish the dashboard","Devbox","claude",.working),("Fix weather layout","Build Mac","codex",.finished),("Improve project search","Devbox","claude",.working),("Update documentation","Build Mac","codex",.working),("Review test coverage","Devbox","claude",.working),("Improve keyboard shortcuts","Build Mac","codex",.working),("Simplify account settings","Devbox","claude",.working),("Polish widget spacing","Build Mac","codex",.working),("Speed up project loading","Devbox","claude",.working)]
        let rows=values.enumerated().map {index,value -> SessionRow in
            let session=AgentSession(id:"sample-\(index)",provider:value.2,title:value.0,project:index==2 ? "weather" : "dashboard",state:value.3,updatedAt:now.addingTimeInterval(Double(-index*120)))
            return SessionRow(hostID:value.1,hostName:value.1,session:session,completionPending:value.3 == .finished,completionObservedAt:now)
        }
        let agents=PublishedAgents.make(rows:rows,sourceObservations:["Build Mac":now.addingTimeInterval(-120),"Devbox":now.addingTimeInterval(-60)],interval:.minutes15,showFinished:false,at:now)
        return PublishedWidgetFeed(publisherID:UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,publisherName:"Display Mac",publishedAt:now,
                                   widgets:[PublishedWidget(id:UUID(uuidString:"00000000-0000-0000-0000-000000000002")!,name:"Agents",agents:agents)])
    }
}
