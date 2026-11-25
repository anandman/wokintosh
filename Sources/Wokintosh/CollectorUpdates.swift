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
    var collectorUpdateCount:Int {
        guard !document.previewMode else{return 0}
        return document.remoteHosts.filter{$0.enabled && collectorUpdate(for:feeds[$0.id.uuidString])?.needsUpdate == true}.count
    }
}
