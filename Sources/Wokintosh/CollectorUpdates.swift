import AppKit
import CryptoKit
import Foundation
import WokintoshCore

enum BundledCollector {
    static func info(source:Data)->CollectorInfo? {
        guard source.starts(with:Data("#!".utf8)),let newline=source.firstIndex(of:10) else{return nil}
        let body=source[source.index(after:newline)...]
        let header=String(decoding:body.prefix(4096),as:UTF8.self)
        let prefix="COLLECTOR_VERSION = '"
        guard let line=header.split(separator:"\n").first(where:{$0.hasPrefix(prefix)}),line.hasSuffix("'") else{return nil}
        let version=String(line.dropFirst(prefix.count).dropLast())
        let info=CollectorInfo(version:version,revision:SHA256.hash(data:body).map{String(format:"%02x",$0)}.joined())
        return info.isValid ? info : nil
    }
}

extension DashboardStore {
    func collectorUpdate(for feed:FeedStatus?)->CollectorUpdate? {
        guard let feed,feed.connected,let bundled=bundledCollectorInfo else{return nil}
        return CollectorUpdate.status(reported:feed.snapshot?.collector,bundled:bundled)
    }
    var collectorUpdateCount:Int {collectorUpdateTargets.count}

    private var collectorUpdateTargets:[(id:String,name:String,info:CollectorInfo?,update:CollectorUpdate)] {
        guard !document.previewMode else{return []}
        var targets:[(id:String,name:String,info:CollectorInfo?,update:CollectorUpdate)]=[]
        if let update=collectorUpdate(for:feeds["local"]),update.needsUpdate {
            targets.append(("local","This Mac",feeds["local"]?.snapshot?.collector,update))
        }
        for host in document.remoteHosts where host.enabled {
            let feed=feeds[host.id.uuidString]
            guard let update=collectorUpdate(for:feed),update.needsUpdate else{continue}
            targets.append((host.id.uuidString,host.name,feed?.snapshot?.collector,update))
        }
        return targets
    }

    func notifyCollectorUpdates() {
        guard !document.previewMode,let presentMessage,let bundled=bundledCollectorInfo else{return}
        if collectorNotificationReceipts == nil {collectorNotificationReceipts=loadCollectorNotificationReceipts()}
        let seen=Set(collectorNotificationReceipts ?? []).union(queuedCollectorNotifications)
        let unseen=collectorUpdateTargets.compactMap {target->(key:String,name:String)? in
            let kind=target.update == .observerUpdateAvailable ? "observer" : "collector"
            let identity=[target.id,bundled.revision,target.info?.revision ?? "legacy",kind].joined(separator:"\0")
            let key=SHA256.hash(data:Data(identity.utf8)).map{String(format:"%02x",$0)}.joined()
            guard !seen.contains(key) else{return nil}
            let name=target.name.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
            return (key,String(name.prefix(90)))
        }
        guard !unseen.isEmpty else{return}
        let keys=unseen.map(\.key)
        queuedCollectorNotifications.formUnion(keys)
        var names=unseen.prefix(8).map{"• \($0.name)"}.joined(separator:"\n")
        if unseen.count>8 {names += "\n• \(unseen.count-8) more machines"}
        let message="Review collector or status-observer updates for:\n\n"+names+"\n\nOpen Machines to review and update them. Existing hook settings and session state are preserved."
        presentMessage(AppMessage(title:"Collector Updates Available",message:message,action:.reviewCollectorUpdates,receipt:.collectorUpdates(keys)))
    }

    func acknowledgeAppMessage(_ message:AppMessage) {
        guard case let .collectorUpdates(keys)=message.receipt else{return}
        let previous=collectorNotificationReceipts ?? loadCollectorNotificationReceipts()
        let seen=Set(previous)
        let next=Array((previous+keys.filter{!seen.contains($0)}).suffix(512))
        collectorNotificationReceipts=next
        do {
            try FileManager.default.createDirectory(at:dataDirectory,withIntermediateDirectories:true)
            let url=dataDirectory.appendingPathComponent("collector-update-notices.json")
            try JSONEncoder().encode(next).write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        } catch { /* Keep this run quiet; a failed receipt write may remind again after relaunch. */ }
    }

    func respondToAppMessage(_ message:AppMessage,response:NSApplication.ModalResponse) {
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else{return}
        acknowledgeAppMessage(message)
        if response == .alertFirstButtonReturn,let action=message.action {performMessageAction(action)}
    }

    func performMessageAction(_ action:AppMessage.Action) {
        switch action {case .reviewCollectorUpdates:openSettings(.machines)}
    }

    private func loadCollectorNotificationReceipts()->[String] {
        let url=dataDirectory.appendingPathComponent("collector-update-notices.json")
        guard let handle=try? FileHandle(forReadingFrom:url) else{return []}
        defer{try? handle.close()}
        guard let data=try? handle.read(upToCount:65537),data.count<=65536,
              let keys=try? JSONDecoder().decode([String].self,from:data),keys.count<=512 else{return []}
        return keys.filter{$0.utf8.count==64 && $0.utf8.allSatisfy{(48...57).contains($0) || (97...102).contains($0)}}
    }
}
