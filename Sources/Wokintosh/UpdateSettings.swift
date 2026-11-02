import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateController
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }

    var body: some View {
        Form {
            Section("Wokintosh \(version)") {
                if let unavailable = updates.state.unavailableReason {
                    Text(unavailable).foregroundStyle(.secondary)
                } else {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updates.state.automaticallyChecks }, set: updates.setAutomaticallyChecks))
                    Toggle("Download updates and install when Wokintosh quits", isOn: Binding(
                        get: { updates.state.automaticallyDownloads }, set: updates.setAutomaticallyDownloads))
                        .disabled(!updates.state.automaticallyChecks)
                    Text("Updates are checked about once a day. Your dashboard stays running until you quit or choose Install and Relaunch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let version = updates.state.availableVersion {
                    Label(updates.state.readyToInstall ? "Version \(version) is ready to install" : "Version \(version) is available", systemImage: "arrow.down.circle")
                }
                Button(updates.menuTitle) { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
                if let date = updates.state.lastCheck {
                    LabeledContent("Last checked", value: date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                if let issue = updates.state.issue {
                    Text(issue).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }.formStyle(.grouped)
    }
}
