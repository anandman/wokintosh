import AppKit
import SwiftUI
import WokintoshCore

struct SettingsView: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $store.settingsTab) {
                WidgetSettingsView(store: store)
                    .tabItem { Label("Widgets", systemImage: "square.grid.2x2") }.tag(SettingsTab.widgets)
                ConnectionsSettingsView(store: store)
                    .tabItem { Label("Connections", systemImage: "link") }.tag(SettingsTab.connections)
                MachinesSettingsView(store: store)
                    .tabItem { Label("Machines", systemImage: "desktopcomputer") }.tag(SettingsTab.machines)
                AppearanceSettingsView(store: store)
                    .tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(SettingsTab.appearance)
                DisplaySettingsView(store: store)
                    .tabItem { Label("Display", systemImage: "display") }.tag(SettingsTab.display)
            }
            .padding(16)
            if let notice = store.notice {
                Divider()
                Text(notice).font(.caption).textSelection(.enabled).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .frame(minWidth: 820, minHeight: 680)
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var store: DashboardStore
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Dashboard") {
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: $store.document.textScale, in: 0.8...1.6, step: 0.05)
                            .accessibilityLabel("Dashboard text size")
                        Text("\(Int(store.document.textScale * 100))%").monospacedDigit().frame(width: 45, alignment: .trailing)
                    }.frame(maxWidth: 330)
                }
                Toggle("Use sample data", isOn: $store.document.previewMode)
                Text("Sample data is fictional and labeled PREVIEW on the dashboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Layout editing") {
                Toggle("Snap widgets to a 16-pixel grid", isOn: $store.document.snapToGrid)
                Button("Open Layout Editor…") { store.showEditor?() }
                Button("Restore Default Layout…", role: .destructive) { confirmReset = true }
                Text("Restoring the layout replaces the dashboard’s widgets. Connections and display preferences stay saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restore the default widget layout?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Restore Default Layout", role: .destructive) { store.resetLayout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current widgets and their individual content settings.")
        }
    }
}

private struct DisplaySettingsView: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        Form {
            Section("Presentation") {
                Picker("Display", selection: Binding<UInt32>(
                    get: { store.document.displayID ?? screenID(NSScreen.main) },
                    set: { store.document.displayID = $0 }
                )) {
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                        Text("\(index + 1). \(screen.localizedName)").tag(screenID(screen))
                    }
                    if let selected = store.document.displayID,
                       !NSScreen.screens.contains(where: { screenID($0) == selected }) {
                        Text("Disconnected display").tag(selected)
                    }
                }
                Toggle("Use native fullscreen", isOn: $store.document.nativeFullscreen)
                Button("Present on Display") { store.presentDashboard?(store.document.displayID) }
                    .buttonStyle(.borderedProminent)
                Text("Escape returns the dashboard to a window. Command-comma opens Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Actual-size preview") {
                Text("The dashboard targets a 5-inch, 1280 × 720 display. Use the Layout Editor’s actual-size preview and ruler calibration to check readability.")
                    .foregroundStyle(.secondary)
                Button("Open Layout Editor…") { store.showEditor?() }
            }
        }.formStyle(.grouped)
    }

    private func screenID(_ screen: NSScreen?) -> UInt32 {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

extension WidgetKind {
    var settingsSymbol: String {
        switch self {
        case .agents: return "person.2"
        case .music: return "music.note"
        case .system: return "cpu"
        case .clock: return "clock"
        case .weather: return "cloud.sun"
        case .calendar: return "calendar"
        }
    }
}

func widgetSettingsName(_ widget: DashboardWidget, in widgets: [DashboardWidget]) -> String {
    let matching = widgets.filter { $0.kind == widget.kind }
    guard matching.count > 1, let index = matching.firstIndex(where: { $0.id == widget.id }) else { return widget.kind.title }
    return "\(widget.kind.title) \(index + 1)"
}
