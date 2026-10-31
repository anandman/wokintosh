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
                if store.native.musicConnected {
                    Toggle("Read Now Playing from Apple Music", isOn: Binding(
                        get: { store.native.musicEnabled },
                        set: { enabled in
                            store.native.musicEnabled = enabled
                            if enabled { Task { await store.native.refresh(document: store.document) } }
                        }
                    ))
                }
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

struct MachinesSettingsView: View {
    @ObservedObject var store: DashboardStore
    @State private var machineName = ""
    @State private var destination = ""
    @State private var collectorPath = "~/.local/bin/wokintosh-agent"
    @State private var message: String?
    @State private var confirmHooks: String?

    var body: some View {
        Form {
            Section("Agent machines") {
                Text("This Mac is collected automatically. Connect another Mac or Linux host over SSH with keys.")
                    .font(.caption).foregroundStyle(.secondary)
                List {
                    machineRow(name: "This Mac", detail: "Local collector", feed: store.feeds["local"])
                    ForEach(store.document.remoteHosts) { host in
                        HStack {
                            machineRow(name: host.name, detail: host.destination, feed: store.feeds[host.id.uuidString], enabled: host.enabled)
                            Spacer()
                            Button("Remove", role: .destructive) { store.document.remoteHosts.removeAll { $0.id == host.id } }
                        }
                    }
                }.frame(height: 130).accessibilityLabel("Connected agent machines")
                HStack {
                    TextField("Machine name", text: $machineName)
                    TextField("SSH alias or user@host", text: $destination)
                }
                TextField("Remote collector path", text: $collectorPath)
                HStack {
                    Button("Add Machine") { addMachine() }
                        .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Export Collector…") { exportCollector() }
                    Spacer()
                    Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(store.refreshing)
                }
                Text("Install the executable as ~/.local/bin/wokintosh-agent (Python 3.10+). Configure SSH keys and host trust in Terminal first. Update remote collectors for multiple-drive readings.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            }
            Section("Wokintosh status observers") {
                Text("Named observers report status and preserve existing hooks with backups. They never approve, deny, or continue agent work.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Enable / Update Codex Hooks…") { confirmHooks = "codex" }
                    Button("Enable / Update Claude Code Hooks…") { confirmHooks = "claude" }
                }
                Text("In Codex /hooks, review each Wokintosh event command that needs trust. New or changed commands require review again. Restart affected sessions after updating.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .confirmationDialog("Enable or update Wokintosh status observers?", isPresented: Binding(
            get: { confirmHooks != nil }, set: { if !$0 { confirmHooks = nil } }
        ), titleVisibility: .visible) {
            Button("Enable / Update \(confirmHooks == "codex" ? "Codex" : "Claude Code") Hooks") {
                if let provider = confirmHooks { Task { await store.installHooks(provider: provider) } }
                confirmHooks = nil
            }
            Button("Cancel", role: .cancel) { confirmHooks = nil }
        } message: {
            Text("Wokintosh adds observational event commands and backs up existing settings. Review every new or changed Wokintosh command listed by Codex in /hooks; trust is not one shared approval. Restart affected sessions after updating.")
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

    private func addMachine() {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = collectorPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemoteCommand.arguments(destination: trimmedDestination, collectorPath: trimmedPath) != nil else {
            message = "Use an SSH alias or user@host and an absolute or ~/ collector path, without shell commands."
            return
        }
        let trimmedName = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.document.remoteHosts.append(RemoteHost(name: trimmedName.isEmpty ? trimmedDestination : trimmedName, destination: trimmedDestination, collectorPath: trimmedPath))
        machineName = ""
        destination = ""
        message = nil
        Task { await store.refresh() }
    }

    private func exportCollector() {
        guard let source = store.collectorURL else { message = "Bundled collector is missing."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "wokintosh-agent"
        panel.title = "Export Mac / Linux Collector"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try Data(contentsOf: source).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                message = "Collector exported. Install it on your agent machine, then connect that machine above."
            } catch { message = error.localizedDescription }
        }
    }
}
