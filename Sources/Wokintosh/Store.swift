import AppKit
import Combine
import Foundation
import WokintoshCore

typealias DashboardWidget = WokintoshCore.Widget

struct FeedStatus {
    var name: String
    var snapshot: Snapshot?
    var error: String?
    var refreshedAt: Date?
    var connected: Bool { snapshot != nil && error == nil }
    var displayName: String { name == "This Mac" ? (snapshot?.host.name ?? name) : name }
}

@MainActor final class DashboardStore: ObservableObject {
    @Published var document: DashboardDocument { didSet { scheduleSave() } }
    @Published var selectedID: UUID?
    @Published var feeds: [String: FeedStatus] = [:]
    @Published var refreshing = false
    @Published var notice: String?
    let native = NativeSources()
    let dataDirectory: URL
    private var layoutNeedsBackup=false
    private var saveTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var nativeSubscription: AnyCancellable?
    var showEditor: (() -> Void)?
    var presentDashboard: ((UInt32?) -> Void)?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(index + 1) {
            dataDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wokintosh", isDirectory: true)
        }
        let file = dataDirectory.appendingPathComponent("layout.json")
        var loaded=DashboardDocument.defaultLayout
        var loadNotice:String?
        if FileManager.default.fileExists(atPath:file.path) {
            do { loaded=try JSONDecoder().decode(DashboardDocument.self,from:Data(contentsOf:file)) }
            catch { loadNotice="Saved layout could not be read. Showing defaults; the original will be retained as a backup.";layoutNeedsBackup=true }
        }
        loaded.repairGeometry()
        if arguments.contains("--preview") { loaded.previewMode = true }
        document = loaded
        notice=loadNotice
        selectedID = loaded.widgets.first?.id
        nativeSubscription = native.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }
    func saveNow() {
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let file=dataDirectory.appendingPathComponent("layout.json")
            if layoutNeedsBackup && FileManager.default.fileExists(atPath:file.path) {
                try FileManager.default.copyItem(at:file,to:dataDirectory.appendingPathComponent("layout-backup-"+UUID().uuidString+".json"))
                layoutNeedsBackup=false
            }
            try JSONEncoder().encode(document).write(to:file,options:.atomic)
        } catch { notice = "Could not save layout: \(error.localizedDescription)" }
    }
    var selectedWidget: Widget? { document.widgets.first { $0.id == selectedID } }
    func change(_ id: UUID, _ transform: (inout Widget) -> Void) {
        guard let index = document.widgets.firstIndex(where: { $0.id == id }) else { return }
        transform(&document.widgets[index])
        document.widgets[index].frame = document.widgets[index].frame.clamped(for: document.widgets[index].kind)
    }
    func add(_ kind: WidgetKind) {
        let offset = Double(document.widgets.count % 5) * 0.025
        let widget = Widget(kind: kind, frame: WidgetFrame(x: 0.2 + offset, y: 0.2 + offset, width: 0.4, height: kind == .agents ? 0.5 : 0.3).clamped(for: kind))
        document.widgets.append(widget)
        selectedID = widget.id
    }
    func removeSelected() {
        document.widgets.removeAll { $0.id == selectedID }
        selectedID = document.widgets.first?.id
    }
    func duplicateSelected() {
        guard let widget = selectedWidget else { return }
        var duplicate = Widget(kind: widget.kind, frame: WidgetFrame(x: widget.frame.x + 0.025, y: widget.frame.y + 0.025, width: widget.frame.width, height: widget.frame.height).clamped(for: widget.kind))
        duplicate.hostID=widget.hostID; duplicate.provider=widget.provider; duplicate.showFinished=widget.showFinished; duplicate.showHelpers=widget.showHelpers
        document.widgets.append(duplicate); selectedID=duplicate.id
    }
    func resetLayout() { document.widgets = DashboardDocument.defaultLayout.widgets; selectedID = document.widgets.first?.id }

    var hosts: [HostInfo] {
        var result: [String: HostInfo] = [:]
        for feed in feeds.values { if var host = feed.snapshot?.host { host.name=feed.displayName;result[host.id] = host } }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func rows(for widget: Widget) -> [SessionRow] {
        if document.previewMode { return previewRows().filter { (widget.provider == nil || $0.session.provider == widget.provider) && (widget.hostID == nil || $0.hostID == widget.hostID) } }
        var rows: [String: SessionRow] = [:]
        for feed in feeds.values {
            guard let snapshot = feed.snapshot else { continue }
            if let source = widget.hostID, source != snapshot.host.id { continue }
            for session in snapshot.sessions {
                if let provider = widget.provider, provider != session.provider { continue }
                if !widget.showHelpers && session.parentId != nil { continue }
                // Do not swamp the ambient view with old inactive transcript records.
                let age = Date().timeIntervalSince(session.updatedAt)
                if !widget.showFinished && (session.state == .finished || session.state == .idle || (session.state == .unknown && age > 7200)) { continue }
                if widget.showFinished && age > 86400 { continue }
                let row = SessionRow(hostID: snapshot.host.id, hostName: feed.displayName, session: session, connected: feed.connected)
                if let old = rows[row.id], old.connected && !row.connected { continue }
                rows[row.id] = row
            }
        }
        return Array(rows.values)
    }
    func system(for widget: Widget) -> (String, SystemReading, Bool) {
        if document.previewMode { return ("Minion", SystemReading(cpuPercent: 18, memoryUsedBytes: 12*1024*1024*1024, memoryTotalBytes: 24*1024*1024*1024, diskFreeBytes: 241*1024*1024*1024, diskTotalBytes: 512*1024*1024*1024), true) }
        let feed = widget.hostID.flatMap { id in feeds.values.first { $0.snapshot?.host.id == id } } ?? feeds["local"]
        return (feed?.displayName ?? "This Mac", feed?.snapshot?.system ?? SystemReading(), feed?.connected ?? false)
    }
    var offlineCount: Int { feeds.values.filter { $0.error != nil }.count }
    var collectorURL: URL? { Bundle.main.url(forResource: "wokintosh_agent", withExtension: "py") }
    var pythonPath: String? { ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) } }

    func refresh() async {
        guard !refreshing else { return }
        refreshing=true
        defer { refreshing=false }
        if !document.previewMode { await refreshFeeds(); await native.refresh(document: document) }
    }
    private func refreshFeeds() async {
        struct Request: Sendable { var id: String; var name: String; var executable: String; var arguments: [String] }
        var requests: [Request] = []
        if let collector = collectorURL, let python = pythonPath {
            requests.append(Request(id: "local", name: "This Mac", executable: python, arguments: [collector.path, "snapshot", "--json"]))
        } else { feeds["local"] = FeedStatus(name: "This Mac", error: "Python 3 or the bundled collector is missing") }
        let enabled = document.remoteHosts.filter(\.enabled)
        let allowed = Set(enabled.map { $0.id.uuidString }).union(["local"])
        feeds = feeds.filter { allowed.contains($0.key) }
        for host in enabled {
            if let arguments = RemoteCommand.arguments(destination: host.destination, collectorPath: host.collectorPath) {
                requests.append(Request(id: host.id.uuidString, name: host.name, executable: "/usr/bin/ssh", arguments: arguments))
            } else { feeds[host.id.uuidString] = FeedStatus(name: host.name, error: "Check the SSH destination and collector path") }
        }
        await withTaskGroup(of: (String, String, Snapshot?, String?).self) { group in
            for request in requests {
                group.addTask {
                    do {
                        let snapshot = try await Task.detached(priority:.utility) {
                            let data=try CommandRunner.run(request.executable,arguments:request.arguments,timeout:12)
                            return try Snapshot.decode(data)
                        }.value
                        return (request.id, request.name, snapshot, nil)
                    } catch { return (request.id, request.name, nil, error.localizedDescription) }
                }
            }
            for await (id, name, snapshot, error) in group {
                if id != "local" && !document.remoteHosts.contains(where:{$0.id.uuidString == id && $0.enabled}) { continue }
                if let snapshot { feeds[id] = FeedStatus(name: name, snapshot: snapshot, refreshedAt: Date()) }
                else { var previous = feeds[id] ?? FeedStatus(name: name); previous.error=error; previous.refreshedAt=Date(); feeds[id]=previous }
            }
        }
    }

    func installHooks(provider: String) async {
        guard ["codex", "claude"].contains(provider), let python = pythonPath, let collector = collectorURL else { notice="Collector unavailable"; return }
        do {
            let helpers=dataDirectory.appendingPathComponent("bin",isDirectory:true)
            try FileManager.default.createDirectory(at:helpers,withIntermediateDirectories:true)
            let installed=helpers.appendingPathComponent("wokintosh-agent.py")
            try Data(contentsOf:collector).write(to:installed,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:installed.path)
            let result = try await Task.detached { try CommandRunner.run(python, arguments: [installed.path, "install-hooks", "--provider", provider], timeout: 5) }.value
            notice=String(data: result, encoding: .utf8)
        } catch { notice=error.localizedDescription }
    }
    func previewRows() -> [SessionRow] {
        let names=["Calendar sync", "Collector tests", "Window layout", "Auth review", "Weather cache", "Music metadata", "Layout persistence", "Release notes", "Parser coverage", "Linux collector", "Artwork cache", "Window placement"]
        return names.enumerated().map { index, title in
            let provider = [0,3,5,7,9,11].contains(index) ? "claude" : "codex"
            return SessionRow(hostID: index == 4 || index == 5 ? "minion" : "dev", hostName: index == 4 || index == 5 ? "Minion" : "Dev Mini", session: AgentSession(id: "preview-\(index)", provider: provider, title: title, project: "wokintosh", state: index < 2 ? .needsAttention : .working, updatedAt: Date().addingTimeInterval(Double(-index*17)), activity: index < 2 ? "Approval needed" : "Working"))
        }
    }
}
