import AppKit
import SwiftUI
import WokintoshCore

struct ConnectionsSettingsView: View {
    @ObservedObject var store: DashboardStore
    @State private var refreshingAccess = false

    var body: some View {
        Form {
            Section("Apple Music") {
                ConnectionStatusLabel(connected: store.native.musicConnected, known: store.native.musicConnectionKnown)
                Text(store.native.music.status).foregroundStyle(.secondary)
                if !store.native.music.artworkStatus.isEmpty { Text(store.native.music.artworkStatus).font(.caption).foregroundStyle(.secondary) }
                if store.native.musicConnected {
                    Toggle("Read Now Playing from Apple Music", isOn: Binding(
                        get: { store.native.musicEnabled },
                        set: { enabled in
                            store.native.musicEnabled = enabled
                            if enabled { Task { await store.native.refresh(document: store.document) } }
                        }
                    ))
                }
                Toggle("Look up missing artwork in Apple’s catalog", isOn: Binding(
                    get: { store.native.musicCatalogArtworkEnabled },
                    set: { enabled in
                        store.native.musicCatalogArtworkEnabled = enabled
                        Task { await store.native.refresh(document: store.document) }
                    }
                ))
                Text("When Music does not expose a cover, send the current title, artist and album to Apple to find a matching cover.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(store.native.musicConnectionKnown && !store.native.musicConnected ? "Connect Apple Music…" : "Refresh Access") {
                        refreshAccess { if store.native.musicConnectionKnown && !store.native.musicConnected { await store.native.connectMusic() } }
                    }.disabled(refreshingAccess)
                    Button("Manage Permissions…") { openPrivacy("Privacy_Automation") }
                }
                Text("Apple Music must be open to read its current track. Access status is separate from playback.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Calendar") {
                ConnectionStatusLabel(connected: store.native.calendar.authorized)
                Text(store.native.calendar.status).foregroundStyle(.secondary)
                HStack {
                    Button(store.native.calendar.authorized ? "Refresh Access" : "Connect Calendar…") {
                        refreshAccess { if !store.native.calendar.authorized { await store.native.requestCalendarAccess() } }
                    }.disabled(refreshingAccess)
                    Button("Manage Permissions…") { openPrivacy("Privacy_Calendars") }
                }
                Text("Choose calendars, title filters, and event display options in each Calendar widget’s Content settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Permission is requested only when you connect a source. Weather locations are configured separately for each Weather widget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func refreshAccess(_ connect: @escaping () async -> Void) {
        refreshingAccess = true
        Task {
            await connect()
            await store.native.refreshConnectionStatus()
            refreshingAccess = false
        }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ConnectionStatusLabel: View {
    let connected: Bool
    var known = true
    var body: some View {
        if known {
            Label(connected ? "Connected" : "Not connected", systemImage: connected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(connected ? Color.green : Color.secondary)
                .accessibilityLabel(connected ? "Connection access granted" : "Connection access not granted")
        } else {
            Label("Open Apple Music to verify access", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct MachinesSettingsView: View {
    @ObservedObject var store: DashboardStore
    @State private var machineName = ""
    @State private var destination = ""
    @State private var collectorPath = "~/.local/bin/wokintosh-agent"
    @State private var message: String?
    @State private var confirmHooks: String?
    @State private var pendingInstall: RemoteHost?
    @State private var working = false
    @State private var progress = ""

    var body: some View {
        Form {
            Section("Agent machines") {
                Text("This Mac is collected automatically. Add another Mac or Linux machine using its existing SSH keys and host trust.")
                    .font(.caption).foregroundStyle(.secondary)
                machineRow(name: "This Mac", detail: "Local collector", feed: store.feeds["local"])
                ForEach(store.document.remoteHosts) { host in
                    VStack(alignment: .leading, spacing: 8) {
                        machineRow(name: host.name, detail: host.destination, feed: store.feeds[host.id.uuidString], enabled: host.enabled)
                        HStack {
                            Button("Install / Update…") { pendingInstall = host }
                                .help("Upload the bundled collector to this machine’s saved path")
                                .accessibilityLabel("Install or update \(host.name)")
                            Button("Remove", role: .destructive) { store.document.remoteHosts.removeAll { $0.id == host.id } }
                                .accessibilityLabel("Remove \(host.name)")
                        }.disabled(working)
                    }.padding(.vertical, 3)
                }
            }
            Section("Add a remote machine") {
                TextField("Machine name", text: $machineName)
                TextField("SSH alias or user@host", text: $destination)
                TextField("Remote collector path", text: $collectorPath)
                VStack(alignment: .leading, spacing: 8) {
                    Button("Install / Update over SSH…") { if let host = formHost() { pendingInstall = host } }
                        .buttonStyle(.borderedProminent)
                        .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                    HStack {
                        Button("Connect Existing Collector") { if let host = formHost() { connect(host) } }
                            .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                        Menu("Advanced") {
                            Button("Save Collector to File…") { exportCollector() }
                        }.disabled(working)
                        Spacer()
                    }
                }
                Text("Install copies this app’s collector with SCP and verifies Python 3.10+ and a working snapshot. Connect Existing only verifies a collector you already installed. Set up SSH keys and host trust in Terminal first.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Observer hooks are optional and configured on each machine separately. Installing a collector preserves its state and existing hook settings.")
                    .font(.caption).foregroundStyle(.secondary)
                if working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.caption).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
                if let message {
                    HStack(alignment: .top) {
                        Text(message).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button { self.message = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss machine information")
                    }
                }
                Button { Task { await store.refresh() } } label: { Label("Refresh Machines", systemImage: "arrow.clockwise") }
                    .disabled(store.refreshing || working)
            }
            .disabled(working)
            Section("Observers on This Mac") {
                Text("Optional named observers report status and preserve existing hooks with backups. These buttons update this Mac only. They never approve, deny, or continue agent work.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Button("Enable / Update Codex Hooks…") { confirmHooks = "codex" }
                    Button("Enable / Update Claude Code Hooks…") { confirmHooks = "claude" }
                }.disabled(working)
                Text("In Codex /hooks, review each new or changed Wokintosh event command that needs trust. Reload or restart affected clients after updating observers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: store.settingsTab) { _, tab in if tab != .machines { message = nil } }
        .textFieldStyle(.roundedBorder)
        .confirmationDialog("Install or update the remote collector?", isPresented: Binding(
            get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } }
        ), titleVisibility: .visible) {
            Button("Install / Update over SSH") {
                if let host = pendingInstall { install(host) }
                pendingInstall = nil
            }
            Button("Cancel", role: .cancel) { pendingInstall = nil }
        } message: {
            if let host = pendingInstall {
                Text("Copy the bundled collector to \(host.collectorPath) on \(host.destination). If a file already exists there, keep a backup beside it before replacing it. Restore the previous collector if verification fails. Existing collector state and hook settings are preserved.")
            }
        }
        .confirmationDialog("Enable or update observers on This Mac?", isPresented: Binding(
            get: { confirmHooks != nil }, set: { if !$0 { confirmHooks = nil } }
        ), titleVisibility: .visible) {
            Button("Enable / Update \(confirmHooks == "codex" ? "Codex" : "Claude Code") Hooks") {
                if let provider = confirmHooks { Task { await store.installHooks(provider: provider) } }
                confirmHooks = nil
            }
            Button("Cancel", role: .cancel) { confirmHooks = nil }
        } message: {
            Text(confirmHooks == "codex"
                 ? "Wokintosh adds observational event commands on this Mac and backs up existing settings. Review every new or changed Wokintosh command listed by Codex in /hooks. Restart affected sessions after updating."
                 : "Wokintosh adds observational Claude Code event commands on this Mac and backs up existing settings. Reload or restart affected Claude Code clients after updating.")
        }
    }

    private func machineRow(name: String, detail: String, feed: FeedStatus?, enabled: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: feed?.connected == true && enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(feed?.connected == true && enabled ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text(!enabled ? "Disabled" : (feed?.error ?? (feed?.connected == true ? "Connected" : "Waiting for collector")))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func formHost() -> RemoteHost? {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = collectorPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemoteCommand.arguments(destination: trimmedDestination, collectorPath: trimmedPath) != nil else {
            report("Check Machine Details", "Use an SSH alias or user@host and an absolute or ~/ collector file path, without shell commands or .. components.")
            return nil
        }
        let trimmedName = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = store.document.remoteHosts.first { $0.destination == trimmedDestination && $0.collectorPath == trimmedPath }
            ?? RemoteHost(name: trimmedName.isEmpty ? trimmedDestination : trimmedName, destination: trimmedDestination, collectorPath: trimmedPath)
        if !trimmedName.isEmpty { host.name = trimmedName }
        return host
    }

    private func install(_ host: RemoteHost) {
        guard !working else { return }
        guard let collector = store.collectorURL else { report("Collector Unavailable", "The app’s bundled collector is missing. Reinstall Wokintosh, then retry."); return }
        working = true
        message = nil
        progress = "Checking SSH…"
        Task {
            defer { working = false; progress = "" }
            do {
                let result = try await RemoteInstaller.install(host: host, collectorURL: collector) { value in
                    Task { @MainActor in progress = value }
                }
                saveConnectedHost(host, snapshot: result.snapshot)
                var details = "Installed and verified on \(host.name) using Python \(result.pythonVersion)."
                if let backup = result.backupPath { details += " Previous collector: \(backup)" }
                if let warning = result.cleanupWarning { details += " \(warning)" }
                if store.settingsTab == .machines { message = details }
            } catch { report("Could Not Install on \(host.name)", error.localizedDescription) }
        }
    }

    private func connect(_ host: RemoteHost) {
        guard !working else { return }
        working = true
        message = nil
        progress = "Checking the existing collector over SSH…"
        Task {
            defer { working = false; progress = "" }
            do {
                let snapshot = try await RemoteInstaller.connect(host: host)
                saveConnectedHost(host, snapshot: snapshot)
                if store.settingsTab == .machines { message = "Connected to the existing collector on \(host.name)." }
            } catch { report("Could Not Connect to \(host.name)", error.localizedDescription) }
        }
    }

    private func saveConnectedHost(_ host: RemoteHost, snapshot: Snapshot) {
        if let index = store.document.remoteHosts.firstIndex(where: { $0.id == host.id }) {
            store.document.remoteHosts[index] = host
        } else {
            store.document.remoteHosts.append(host)
        }
        store.feeds[host.id.uuidString] = FeedStatus(name: host.name, snapshot: snapshot, refreshedAt: Date())
        if destination.trimmingCharacters(in: .whitespacesAndNewlines) == host.destination {
            machineName = ""
            destination = ""
        }
    }

    private func report(_ title: String, _ text: String) {
        store.presentMessage?(AppMessage(title: title, message: text, isError: true))
    }

    private func exportCollector() {
        guard let source = store.collectorURL else { report("Collector Unavailable", "The app’s bundled collector is missing."); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "wokintosh-agent"
        panel.title = "Save Collector to a Local File"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try Data(contentsOf: source).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                message = "Collector saved to \(url.path). Copy it to your machine yourself, then use Connect Existing Collector."
            } catch { report("Could Not Save Collector", error.localizedDescription) }
        }
    }
}
