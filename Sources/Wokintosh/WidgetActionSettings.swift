import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WokintoshCore

struct WidgetActionSettings: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget
    @State private var errorText: String?

    private enum ApplicationSlot {
        case widget, codex, claude

        var chooserIdentifier: String {
            switch self {
            case .widget: return "widgetActionAppChooser"
            case .codex: return "widgetActionCodexAppChooser"
            case .claude: return "widgetActionClaudeAppChooser"
            }
        }

        var label: String {
            switch self {
            case .widget: return "Application"
            case .codex: return "Codex app"
            case .claude: return "Claude Code app"
            }
        }
    }

    private struct ApplicationChoice {
        let bundleID: String
        let name: String
    }

    // Read from the store so edits never restore an older copy of this widget.
    private var currentWidget: DashboardWidget {
        store.document.widgets.first { $0.id == widget.id } ?? widget
    }

    var body: some View {
        Form {
            Section("On click") {
                Picker("Click action", selection: actionBinding(\.kind)) {
                    Text("Do nothing").tag(WidgetActionKind.none)
                    Text("Open app").tag(WidgetActionKind.openApplication)
                    Text("Open link").tag(WidgetActionKind.openURL)
                    if currentWidget.kind == .agents {
                        Text("Open harness app").tag(WidgetActionKind.openAgentApp)
                    }
                }
                .accessibilityIdentifier("widgetActionKind")
                Text("App and link actions run on the dashboard. Use Test Action to try your selection here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            actionDetails

            if let errorText {
                Section {
                    Text(errorText).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        .accessibilityIdentifier("widgetActionError")
                }
            }

            if currentWidget.action.kind != .none {
                Section("Test action") {
                    if currentWidget.action.kind == .openAgentApp {
                        testButton("Test Codex App", provider: "codex", identifier: "widgetActionTestCodex")
                        testButton("Test Claude App", provider: "claude", identifier: "widgetActionTestClaude")
                    } else {
                        testButton("Test Action", identifier: "widgetActionTest")
                    }
                    Text("Testing opens the configured app or link on this Mac, including in preview mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var actionDetails: some View {
        switch currentWidget.action.kind {
        case .none:
            Section {
                Text("This widget has no click action.").foregroundStyle(.secondary)
            }
        case .openApplication:
            Section("Application") {
                applicationControls(.widget)
                if let suggestion = suggestedApplication,
                   suggestion.bundleID != currentWidget.action.applicationBundleID {
                    Button("Use \(suggestion.name)") { setApplication(suggestion, for: .widget) }
                        .accessibilityIdentifier("widgetActionSuggestedApp")
                }
                if currentWidget.kind == .weather {
                    Text("To open CARROT Weather, use Choose App… to select its installed app. This can also be an iPhone or iPad app installed on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if currentWidget.kind == .system {
                    Text("The app opens on this Mac. Activity Monitor shows this Mac’s processes, even when the widget shows a remote machine.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .openURL:
            Section("Link") {
                TextField("URL", text: actionBinding(\.url), prompt: Text("https://example.com"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("widgetActionLink")
                if !currentWidget.action.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let message = validationMessage() {
                    Text(message).font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("widgetActionLinkValidation")
                }
                Text("Enter a complete web or application link, such as https://example.com. Web links open in this Mac’s default browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .openAgentApp:
            Section("Harness apps") {
                applicationControls(.codex)
                applicationControls(.claude)
                Text("Opens the chosen app for the clicked session’s harness on this Mac. Opening the app does not select a specific session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func applicationControls(_ slot: ApplicationSlot) -> some View {
        let choice = applicationChoice(for: slot)
        let installedURL = installedApplication(choice.bundleID)
        let name = choice.name.isEmpty ? installedURL.map(applicationName) ?? fallbackName(for: slot) : choice.name
        return VStack(alignment: .leading, spacing: 7) {
            LabeledContent(slot.label) {
                Text(name).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(choice.bundleID.isEmpty ? "No app selected" : installedURL == nil ? "Not found on this Mac" : "Available on this Mac")
                    .font(.caption)
                    .foregroundStyle(choice.bundleID.isEmpty || installedURL != nil ? Color.secondary : Color.orange)
                Spacer(minLength: 8)
                Button("Choose App…") { chooseApplication(for: slot) }
                    .accessibilityLabel("Choose \(slot.label.lowercased())")
                    .accessibilityIdentifier(slot.chooserIdentifier)
            }
        }
    }

    private func testButton(_ title: String, provider: String? = nil, identifier: String) -> some View {
        Button(title) {
            errorText = validationMessage(provider: provider)
            guard errorText == nil else { return }
            store.testWidgetAction(widget.id, provider: provider)
        }
        .disabled(validationMessage(provider: provider) != nil)
        .accessibilityIdentifier(identifier)
    }

    private func actionBinding<Value>(_ keyPath: WritableKeyPath<WidgetAction, Value>) -> Binding<Value> {
        Binding(
            get: { currentWidget.action[keyPath: keyPath] },
            set: { value in
                errorText = nil
                store.change(widget.id) { $0.action[keyPath: keyPath] = value }
            }
        )
    }

    private func validationMessage(provider: String? = nil) -> String? {
        do {
            guard let target = try currentWidget.action.target(provider: provider) else { return "Choose a click action first." }
            if case .application(let bundleID) = target, installedApplication(bundleID) == nil {
                return "This app was not found on this Mac. Use Choose App… to select an installed app."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func applicationChoice(for slot: ApplicationSlot) -> ApplicationChoice {
        let action = currentWidget.action
        switch slot {
        case .widget: return ApplicationChoice(bundleID: action.applicationBundleID, name: action.applicationName)
        case .codex: return ApplicationChoice(bundleID: action.codexBundleID, name: action.codexApplicationName)
        case .claude: return ApplicationChoice(bundleID: action.claudeBundleID, name: action.claudeApplicationName)
        }
    }

    private func fallbackName(for slot: ApplicationSlot) -> String {
        let choice = applicationChoice(for: slot)
        if choice.bundleID.isEmpty { return "None" }
        if slot == .codex, choice.bundleID == "com.openai.codex" { return "Codex" }
        if slot == .claude, choice.bundleID == "com.anthropic.claudefordesktop" { return "Claude" }
        return choice.bundleID
    }

    private func installedApplication(_ bundleID: String) -> URL? {
        guard !bundleID.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private var suggestedApplication: ApplicationChoice? {
        let bundleID: String
        switch currentWidget.kind {
        case .music: bundleID = "com.apple.Music"
        case .clock: bundleID = "com.apple.clock"
        case .system: bundleID = "com.apple.ActivityMonitor"
        case .calendar: bundleID = "com.flexibits.fantastical2.mac"
        case .weather, .agents: return nil
        }
        guard let url = installedApplication(bundleID) else { return nil }
        return ApplicationChoice(bundleID: bundleID, name: applicationName(url))
    }

    private func applicationName(_ url: URL) -> String {
        let bundle = Bundle(url: url)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func setApplication(_ choice: ApplicationChoice, for slot: ApplicationSlot) {
        errorText = nil
        store.change(widget.id) { value in
            switch slot {
            case .widget:
                value.action.applicationBundleID = choice.bundleID
                value.action.applicationName = choice.name
            case .codex:
                value.action.codexBundleID = choice.bundleID
                value.action.codexApplicationName = choice.name
            case .claude:
                value.action.claudeBundleID = choice.bundleID
                value.action.claudeApplicationName = choice.name
            }
        }
    }

    // Selecting a bundle only saves its identity. Launching is confined to Test Action.
    private func chooseApplication(for slot: ApplicationSlot) {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.message = "Choose an app to open on this Mac."
        panel.prompt = "Choose App"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else {
            errorText = "This app does not have a bundle identifier. Choose another application."
            return
        }
        let candidate = WidgetAction(kind: .openApplication, applicationBundleID: bundleID)
        do {
            _ = try candidate.target()
            setApplication(ApplicationChoice(bundleID: bundleID, name: applicationName(url)), for: slot)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
