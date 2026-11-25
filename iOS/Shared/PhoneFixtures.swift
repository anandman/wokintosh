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
        try cache.store(feed(includeControls:true),fetchedAt:Date())
        return PhoneRepository(cache:cache,credentials:credentials,client:PhoneFeedClient())
    }
    #endif
    static func feed(at now:Date=Date(),includeControls:Bool=false)->PublishedWidgetFeed {
        let values:[(String,String,String,AgentState)]=[("Review database migration","Build Mac","codex",.needsAttention),("Polish the dashboard","Devbox","claude",.working),("Fix weather layout","Build Mac","codex",.finished),("Improve project search","Devbox","antigravity",.working),("Update documentation","Build Mac","opencode",.working),("Review test coverage","Devbox","claude",.working),("Improve keyboard shortcuts","Build Mac","codex",.working),("Simplify account settings","Devbox","claude",.working),("Polish widget spacing","Build Mac","codex",.working),("Speed up project loading","Devbox","claude",.working)]
        var rows=values.enumerated().map {index,value -> SessionRow in
            var session=AgentSession(id:"sample-\(index)",provider:value.2,title:value.0,project:index==2 ? "weather" : "dashboard",state:value.3,updatedAt:now.addingTimeInterval(Double(-index*120)))
            if index==0 {
                let poller=BackgroundTask(id:"sample-poller",kind:"shell",label:"Inbox poller",status:.running,startedAt:now.addingTimeInterval(-600),updatedAt:now.addingTimeInterval(-600),observedAt:now,role:.monitor)
                let work=BackgroundTask(id:"sample-build",kind:"shell",label:"Build project",status:.running,startedAt:now.addingTimeInterval(-120),updatedAt:now.addingTimeInterval(-120),observedAt:now)
                session.background=BackgroundTaskEvidence(foregroundState:value.3,foregroundUpdatedAt:session.updatedAt,tasks:[poller,work])
            }
            if index==9 {
                session.title="Watch the inbox"
                let monitor=BackgroundTask(id:"sample-monitor",kind:"monitor",label:"Inbox watcher",status:.running,startedAt:now.addingTimeInterval(-600),updatedAt:now.addingTimeInterval(-600),observedAt:now)
                session.background=BackgroundTaskEvidence(foregroundState:.finished,foregroundUpdatedAt:session.updatedAt,tasks:[monitor])
                session=session.resolvingBackground(at:now)
            }
            return SessionRow(hostID:value.1,hostName:value.1,session:session,completionPending:value.3 == .finished,completionObservedAt:now)
        }
        if includeControls {
            rows.append(SessionRow(hostID:"Build Mac",hostName:"Build Mac",session:AgentSession(id:"sample-earlier",provider:"codex",title:"Review yesterday's build",project:"dashboard",state:.finished,updatedAt:now.addingTimeInterval(-7200)),completionPending:true,completionObservedAt:now.addingTimeInterval(-3600)))
        }
        var agents=PublishedAgents.make(rows:rows,sourceObservations:["Build Mac":now.addingTimeInterval(-120),"Devbox":now.addingTimeInterval(-60)],interval:.minutes15,showFinished:false,at:now)
        if includeControls {
            agents.rows=agents.rows.map {row in
                var copy=row;if let tasks=row.session.background?.activeTasks,!tasks.isEmpty {copy.backgroundControls=PublishedBackgroundControls(revision:String(repeating:"a",count:64),taskIDs:tasks.map(\.id))};copy.controls=PublishedAgentControls(revision:String(repeating:"a",count:64),allowed:row.completionPending ? [.reviewDone,.markBlocked] : [.markBlocked]);return copy
            }
            agents.earlierRows=agents.earlierRows?.map {row in
                var copy=row;if let tasks=row.session.background?.activeTasks,!tasks.isEmpty {copy.backgroundControls=PublishedBackgroundControls(revision:String(repeating:"a",count:64),taskIDs:tasks.map(\.id))};copy.controls=PublishedAgentControls(revision:String(repeating:"a",count:64),allowed:[.reviewDone,.markBlocked]);return copy
            }
            agents.earlierControls=PublishedAgentControls(revision:String(repeating:"a",count:64),allowed:[.reviewEarlierDone])
            agents.controls=PublishedAgentControls(revision:String(repeating:"a",count:64),allowed:[.reviewAllDone])
        }
        return PublishedWidgetFeed(publisherID:UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,publisherName:"Display Mac",publishedAt:now,
                                   widgets:[PublishedWidget(id:UUID(uuidString:"00000000-0000-0000-0000-000000000002")!,name:"Agents",agents:agents)])
    }
}
