import Foundation
import CryptoKit
import WokintoshCore

/// Receipts belong to one authority lifetime. A restart rejects old rendered actions.
@MainActor final class AgentControlAuthority {
    var epoch=UUID()
    var versions:[String:UUID]=[:]
    var applied:[UUID:(AgentControlCommand,Date)]=[:]
    func invalidate(_ id:String) {
        if versions.count>=2048 {epoch=UUID();versions.removeAll();applied.removeAll()}
        versions[id]=UUID()
    }
    func digest(_ value:String)->String {SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined()}
    func revision(_ row:PublishedAgentRow,widget:UUID,manual:Bool)->String {
        digest("\(epoch)|\(widget)|\(row.id)|\(row.session.updatedAt.timeIntervalSinceReferenceDate)|\(row.session.state.rawValue)|\(row.completionPending)|\(row.session.goalBlocked == true)|\(manual)|\(versions[row.id]?.uuidString ?? "initial")")
    }
    func bulk(_ rows:[PublishedAgentRow],widget:UUID)->String {
        digest("\(epoch)|\(widget)|"+rows.filter(\.completionPending).map{$0.id+":"+($0.controls?.revision ?? "")}.sorted().joined(separator:"|"))
    }
    func backgroundRevision(_ row:PublishedAgentRow,widget:UUID)->String {
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        var background=row.session.background
        // Read-only liveness renewal is not a new task incarnation or role change.
        if background != nil {for i in background!.tasks.indices {background!.tasks[i].observedAt=background!.tasks[i].updatedAt}}
        let evidence=(try? encoder.encode(background)).map{String(decoding:$0,as:UTF8.self)} ?? "none"
        return digest("\(epoch)|\(widget)|\(row.id)|\(row.connected)|\(evidence)|\(versions[row.id]?.uuidString ?? "initial")")
    }
}

extension DashboardStore {
    func decorateAgentControls(_ agents:inout PublishedAgents,widgetID:UUID) {
        agents.controls=nil;agents.earlierControls=nil
        guard publisher.options.allowAgentControls,!document.previewMode else {return}
        func decorate(_ row:PublishedAgentRow)->PublishedAgentRow {
            var copy=row
            let manual=document.blockedSessions.contains(row.id)
            var allowed:[AgentControlAction]=[]
            if row.completionPending {allowed.append(.reviewDone)}
            if manual {allowed.append(.clearManualBlocked)}
            else if row.session.state != .blocked && row.session.goalBlocked != true {allowed.append(.markBlocked)}
            if !allowed.isEmpty {copy.controls=PublishedAgentControls(revision:agentControlAuthority.revision(row,widget:widgetID,manual:manual),allowed:allowed)}
            let tasks=currentBackgroundTaskIDs(hostID:row.hostID,session:row.session).sorted()
            if row.connected,!tasks.isEmpty {copy.backgroundControls=PublishedBackgroundControls(revision:agentControlAuthority.backgroundRevision(row,widget:widgetID),taskIDs:tasks)}
            return copy
        }
        agents.rows=agents.rows.map(decorate);agents.earlierRows=agents.earlierRows?.map(decorate)
        if let earlier=agents.earlierRows,earlier.contains(where:{$0.completionPending}) {
            agents.earlierControls=PublishedAgentControls(revision:agentControlAuthority.bulk(earlier,widget:widgetID),allowed:[.reviewEarlierDone])
        }
        let represented=agents.rows+(agents.earlierRows ?? [])
        if represented.contains(where:{$0.completionPending}) {
            agents.controls=PublishedAgentControls(revision:agentControlAuthority.bulk(represented,widget:widgetID),allowed:[.reviewAllDone])
        }
    }
    @discardableResult func applyAgentControl(_ command:AgentControlCommand,at now:Date=Date())throws->Data {
        guard command.isValid,abs(now.timeIntervalSince(command.issuedAt))<=60 else {throw AgentControlError.conflict}
        guard publisher.options.enabled,publisher.options.allowAgentControls,!document.previewMode,
              command.publisherID==publisher.options.publisherID,publisher.options.selectedWidgetIDs.contains(command.widgetID),
              let widget=document.widgets.first(where:{$0.id==command.widgetID && $0.kind == .agents}) else {throw AgentControlError.disabled}
        agentControlAuthority.applied=agentControlAuthority.applied.filter{now.timeIntervalSince($0.value.1)<=120}
        if let previous=agentControlAuthority.applied[command.id] {
            guard previous.0==command else {throw AgentControlError.conflict}
            publishWidgets(at:now);return try currentAgentFeed()
        }
        publishWidgets(at:now)
        let feed=try PublishedWidgetFeed.decode(currentAgentFeed())
        guard let agents=feed.widgets.first(where:{$0.id==widget.id})?.agents else {throw AgentControlError.conflict}
        let represented=agents.rows+(agents.earlierRows ?? [])
        if command.action == .setBackgroundTaskRole {
            guard let row=represented.first(where:{$0.id==command.rowID}),
                  let controls=row.backgroundControls,controls.revision==command.revision,
                  let taskID=command.taskID,controls.taskIDs.contains(taskID),let role=command.taskRole,
                  let current=rows(for:widget).first(where:{$0.id==row.id}) else {throw AgentControlError.conflict}
            try setBackgroundTaskRole(role,taskID:taskID,row:current)
            if agentControlAuthority.applied.count>=2048 {agentControlAuthority.applied.removeAll()}
            agentControlAuthority.applied[command.id]=(command,now)
            publishWidgets(at:now)
            return try currentAgentFeed()
        }
        let targets:[PublishedAgentRow]
        if command.action == .reviewAllDone {
            guard agents.controls?.revision==command.revision,agents.controls?.allowed.contains(.reviewAllDone)==true else {throw AgentControlError.conflict}
            targets=represented.filter(\.completionPending)
        } else if command.action == .reviewEarlierDone {
            guard agents.earlierControls?.revision==command.revision,agents.earlierControls?.allowed.contains(.reviewEarlierDone)==true else {throw AgentControlError.conflict}
            targets=(agents.earlierRows ?? []).filter(\.completionPending)
        } else {
            guard let row=represented.first(where:{$0.id==command.rowID}),row.controls?.revision==command.revision,
                  row.controls?.allowed.contains(command.action)==true else {throw AgentControlError.conflict}
            targets=[row]
        }
        var next=document
        let current=Dictionary(rows(for:widget).map{($0.id,$0)},uniquingKeysWith:{a,_ in a})
        for target in targets {
            guard let row=current[target.id] else {throw AgentControlError.conflict}
            switch command.action {
            case .reviewDone,.reviewAllDone,.reviewEarlierDone:next.completions.review(row.id)
            case .markBlocked:next.blockedSessions.mark(row);next.completions.review(row.id)
            case .clearManualBlocked:next.blockedSessions.clear(row.id)
            case .setBackgroundTaskRole:throw AgentControlError.invalid
            }
        }
        // Persist the transaction before changing the dashboard or acknowledging it.
        try persistDocument(next)
        document=next
        for row in targets {agentControlAuthority.invalidate(row.id)}
        if agentControlAuthority.applied.count>=2048 {agentControlAuthority.applied.removeAll()}
        agentControlAuthority.applied[command.id]=(command,now)
        publishWidgets(at:now)
        return try currentAgentFeed()
    }
    private func currentAgentFeed()throws->Data {
        guard let data=publisher.publishedData else {throw AgentControlError.disabled};return data
    }
}
