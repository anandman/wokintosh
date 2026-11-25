import Foundation
import Darwin
import WokintoshCore

extension DashboardStore {
    func currentBackgroundTaskIDs(hostID:String,session:AgentSession)->Set<String> {
        let displayed=Dictionary(uniqueKeysWithValues:(session.background?.tasks ?? []).map{($0.id,$0.startedAt)})
        let tasks=feeds.values.filter(\.connected).compactMap(\.snapshot).filter{$0.host.id==hostID}
            .flatMap{$0.sessions}.filter{$0.id==session.id && $0.provider==session.provider}
            .flatMap{$0.background?.activeTasks ?? []}
        return Set(tasks.filter{displayed[$0.id]==$0.startedAt}.map(\.id))
    }
    /// Only display bookkeeping is changed. Remote provider execution is untouched.
    func setBackgroundTaskRole(_ role:BackgroundTaskRole,taskID:String,row:SessionRow)throws {
        guard !document.previewMode,row.connected,
              let widget=document.widgets.first(where:{$0.kind == .agents && rows(for:$0).contains(where:{$0.id==row.id})}),
              let current=rows(for:widget).first(where:{$0.id==row.id}),current.connected,
              currentBackgroundTaskIDs(hostID:current.hostID,session:current.session).contains(taskID),
              let task=current.session.background?.tasks.first(where:{$0.id==taskID && $0.status.isActive}),
              row.session.background?.tasks.first(where:{$0.id==taskID})?.startedAt==task.startedAt else {throw AgentControlError.conflict}
        var next=backgroundTaskRoles;next.set(role,for:task,rowID:row.id)
        try FileManager.default.createDirectory(at:dataDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=dataDirectory.appendingPathComponent("background-task-roles.json")
        let temporary=dataDirectory.appendingPathComponent(".background-task-roles-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:temporary)}
        guard FileManager.default.createFile(atPath:temporary.path,contents:try JSONEncoder().encode(next),attributes:[.posixPermissions:0o600]),
              Darwin.rename(temporary.path,file.path)==0 else {throw CocoaError(.fileWriteUnknown)}
        backgroundTaskRoles=next
        agentControlAuthority.invalidate(row.id)
        publishWidgets()
    }
}
