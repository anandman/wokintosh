import SwiftUI
import WokintoshCore

struct WidgetSettingsView: View {
    @ObservedObject var store: DashboardStore
    @State private var inspectorTab = WidgetInspectorTab.content
    @State private var confirmReset = false

    private enum WidgetInspectorTab: Hashable { case content, layout }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            EditorView(store: store)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            inspector
                .frame(minWidth: 330, idealWidth: 360, maxWidth: 360, maxHeight: .infinity)
        }
        .onChange(of: store.selectedID) { _, _ in inspectorTab = .content }
        .confirmationDialog("Restore the default widget layout?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Restore Default Layout", role: .destructive) { store.resetLayout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current widgets and their individual content settings. Connections and display preferences stay saved.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Text("Dashboard Widgets").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            List(selection: $store.selectedID) {
                ForEach(store.document.widgets) { widget in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(widgetSettingsName(widget, in: store.document.widgets), systemImage: widget.kind.settingsSymbol)
                        if widget.kind == .weather {
                            Text(widget.weatherOptions.place.isEmpty ? "Choose a location" : widget.weatherOptions.place)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(widget.id)
                    .contextMenu { WidgetActions(store: store, widget: widget) }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Dashboard widgets")
            Divider()
            HStack {
                Menu {
                    ForEach(WidgetKind.allCases) { kind in
                        Button(kind.title) { store.add(kind) }
                    }
                } label: { Label("Add Widget", systemImage: "plus") }
                .menuStyle(.borderlessButton)
                Spacer()
                Menu {
                    if let widget = store.selectedWidget {
                        WidgetActions(store: store, widget: widget)
                        Divider()
                    }
                    Button("Restore Default Layout…", role: .destructive) { confirmReset = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Dashboard widget actions")
            }.padding(12)
        }.frame(width: 190)
    }

    @ViewBuilder private var inspector: some View {
        if let widget = store.selectedWidget {
            VStack(alignment: .leading, spacing: 12) {
                Label(widgetSettingsName(widget, in: store.document.widgets), systemImage: widget.kind.settingsSymbol)
                    .font(.title3.bold())
                TabView(selection: $inspectorTab) {
                    WidgetContentSettings(store: store, widget: widget)
                        .tabItem { Text("Content") }.tag(WidgetInspectorTab.content)
                    WidgetLayoutSettings(store: store, widget: widget)
                        .tabItem { Text("Layout") }.tag(WidgetInspectorTab.layout)
                }
            }.padding(12)
        } else {
            ContentUnavailableView("Choose a Widget", systemImage: "square.grid.2x2", description: Text("Select a dashboard widget or add one to configure its content and layout."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WidgetContentSettings: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget

    var body: some View {
        switch widget.kind {
        case .weather:
            WeatherWidgetSettings(store: store, widget: widget).id(widget.id)
        case .calendar:
            CalendarWidgetSettings(store: store, widget: widget)
        case .system:
            SystemWidgetSettings(store: store, widget: widget)
        case .agents:
            Form {
                Section("Sessions") {
                    WidgetMachinePicker(store: store, widget: widget)
                    Picker("Harness", selection: Binding(
                        get: { widget.provider ?? "" },
                        set: { value in store.change(widget.id) { $0.provider = value.isEmpty ? nil : value } }
                    )) {
                        Text("Codex + Claude Code").tag("")
                        Text("Codex").tag("codex")
                        Text("Claude Code").tag("claude")
                    }
                    Toggle("Include reviewed or recent inactive sessions", isOn: Binding(
                        get: { widget.showFinished }, set: { value in store.change(widget.id) { $0.showFinished = value } }
                    ))
                    Toggle("Include helper agents", isOn: Binding(
                        get: { widget.showHelpers }, set: { value in store.change(widget.id) { $0.showHelpers = value } }
                    ))
                    Text("Work needing you appears first. Completed work stays marked Done until you review it on the dashboard.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Manage Machines…") { store.openSettings(.machines) }
                }
            }.formStyle(.grouped)
        case .music:
            Form {
                Section("Apple Music") {
                    ConnectionStatusLabel(connected: store.native.musicConnected, known: store.native.musicConnectionKnown)
                    Text(store.native.music.status).foregroundStyle(.secondary)
                    if !store.native.music.artworkStatus.isEmpty { Text(store.native.music.artworkStatus).font(.caption).foregroundStyle(.secondary) }
                    Button("Manage Connections…") { store.openSettings(.connections) }
                }
                Section {
                    Text("Shows the current track, album artwork, and playback controls from Apple Music on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        case .clock:
            Form {
                Section("Clock") {
                    Text("The clock follows this Mac’s locale, time zone, and time settings.").foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
    }
}

private struct WidgetMachinePicker: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget

    var body: some View {
        Picker("Machine", selection: Binding(
            get: { widget.hostID ?? "" },
            set: { value in store.change(widget.id) { $0.hostID = value.isEmpty ? nil : value } }
        )) {
            Text(widget.kind == .agents ? "All machines" : "This Mac").tag("")
            if store.document.previewMode {
                Text("Dev Mini (preview)").tag("dev")
                Text("Minion (preview)").tag("minion")
            }
            ForEach(store.hosts, id: \.id) { host in Text(host.name).tag(host.id) }
            if let selected = widget.hostID,
               !store.hosts.contains(where: { $0.id == selected }),
               !(store.document.previewMode && ["dev", "minion"].contains(selected)) {
                Text("Unavailable machine").tag(selected)
            }
        }
    }
}

private struct SystemWidgetSettings: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget

    var body: some View {
        Form {
            Section("Readings") {
                WidgetMachinePicker(store: store, widget: widget)
                Toggle("CPU usage", isOn: toggle(\.showCPU))
                Toggle("Memory usage", isOn: toggle(\.showMemory))
                Toggle("Drive free space", isOn: toggle(\.showStorage))
            }
            if widget.systemOptions.showStorage {
                Section("Drives") {
                    let drives = store.drives(for: widget)
                    let selected = widget.systemOptions.driveIDs ?? Array(drives.prefix(1).map(\.id))
                    if drives.isEmpty && selected.isEmpty {
                        Text("Connect this machine to discover mounted drives.").foregroundStyle(.secondary)
                    } else {
                        SettingsInventoryScrollView(
                            identifier: "driveInventory",
                            accessibilityLabel: "Mounted drives",
                            items: drives.map { drive in
                                SettingsInventoryItem(id: drive.id, title: drive.name, subtitle: drive.mountPoint, isSelected: selected.contains(drive.id))
                            } + selected.filter { id in !drives.contains { $0.id == id } }.map { id in
                                SettingsInventoryItem(id: id, title: "Unavailable drive", subtitle: id, isSelected: true)
                            },
                            onToggle: { id, on in driveSelection(id, available: drives).wrappedValue = on }
                        )
                        .frame(height: 160)
                    }
                    Text("Older collectors report the startup disk only. Missing drives stay unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Manage Machines…") { store.openSettings(.machines) }
                Text("Resize the widget to reveal additional readings.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func toggle(_ key: WritableKeyPath<SystemWidgetOptions, Bool>) -> Binding<Bool> {
        Binding(get: { widget.systemOptions[keyPath: key] }, set: { value in store.change(widget.id) { $0.systemOptions[keyPath: key] = value } })
    }

    private func driveSelection(_ id: String, available: [DriveReading]) -> Binding<Bool> {
        Binding(get: { (widget.systemOptions.driveIDs ?? Array(available.prefix(1).map(\.id))).contains(id) }, set: { on in
            store.change(widget.id) { value in
                var ids = value.systemOptions.driveIDs ?? Array(available.prefix(1).map(\.id))
                ids.removeAll { $0 == id }
                if on { ids.append(id) }
                value.systemOptions.driveIDs = ids
            }
        })
    }
}

private struct CalendarWidgetSettings: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget

    private var calendars: [CalendarDescriptor] {
        store.document.previewMode
            ? [CalendarDescriptor(id: "personal", title: "Personal", sourceTitle: "Preview"), CalendarDescriptor(id: "work", title: "Work", sourceTitle: "Preview")]
            : store.native.calendar.calendars
    }

    var body: some View {
        Form {
            Section("Events") {
                Toggle("Include all-day events", isOn: Binding(
                    get: { widget.calendarOptions.includeAllDay }, set: { on in store.change(widget.id) { $0.calendarOptions.includeAllDay = on } }
                ))
                Toggle("Show only the next event", isOn: Binding(
                    get: { widget.calendarOptions.nextEventOnly }, set: { on in store.change(widget.id) { $0.calendarOptions.nextEventOnly = on } }
                ))
            }
            Section("Calendars") {
                Toggle("All calendars", isOn: Binding(
                    get: { widget.calendarOptions.calendarIDs == nil },
                    set: { on in store.change(widget.id) { $0.calendarOptions.calendarIDs = on ? nil : [] } }
                ))
                if calendars.isEmpty {
                    Text("Connect Calendar to choose individual calendars.").font(.caption).foregroundStyle(.secondary)
                } else {
                    SettingsInventoryScrollView(
                        identifier: "calendarInventory",
                        accessibilityLabel: "Calendars for this widget",
                        items: calendars.map { calendar in
                            SettingsInventoryItem(id: calendar.id, title: calendar.title, subtitle: calendar.sourceTitle,
                                                  isSelected: widget.calendarOptions.calendarIDs?.contains(calendar.id) ?? true)
                        },
                        onToggle: { id, on in calendarSelection(id).wrappedValue = on }
                    )
                    .frame(height: 160)
                }
                HStack {
                    if widget.calendarOptions.calendarIDs?.isEmpty == true {
                        Text("No calendars selected").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Manage Connections…") { store.openSettings(.connections) }
                }
            }
            Section("Title filters") {
                Text("Hide titles containing any text below. Enter one phrase per line; matching ignores capitalization.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { widget.calendarOptions.excludedTitlePatterns.joined(separator: "\n") },
                    set: { text in store.change(widget.id) { $0.calendarOptions.excludedTitlePatterns = text.components(separatedBy: .newlines) } }
                ))
                .font(.body).frame(height: 54)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                .accessibilityLabel("Hidden title phrases, one per line, case insensitive")
                Toggle("Prefer original titles over same-time generic mirrors", isOn: Binding(
                    get: { widget.calendarOptions.collapseMirrors }, set: { on in store.change(widget.id) { $0.calendarOptions.collapseMirrors = on } }
                ))
            }
        }.formStyle(.grouped)
    }

    private func calendarSelection(_ id: String) -> Binding<Bool> {
        Binding(get: { widget.calendarOptions.calendarIDs?.contains(id) ?? true }, set: { on in
            store.change(widget.id) { value in
                var ids = value.calendarOptions.calendarIDs ?? calendars.map(\.id)
                ids.removeAll { $0 == id }
                if on { ids.append(id) }
                value.calendarOptions.calendarIDs = ids
            }
        })
    }
}

private struct WidgetLayoutSettings: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget

    var body: some View {
        Form {
            Section("Position and size") {
                LabeledContent("Position") {
                    HStack {
                        frameField("X", key: \.x, dimension: 1280)
                        frameField("Y", key: \.y, dimension: 682)
                    }.frame(maxWidth: 300)
                }
                LabeledContent("Size") {
                    HStack {
                        frameField("Width", key: \.width, dimension: 1280)
                        frameField("Height", key: \.height, dimension: 682)
                    }.frame(maxWidth: 300)
                }
                Text("Values are dashboard pixels. Sizes stay within the dashboard and each widget’s minimum readable size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Move widgets by their title bars and resize them with the purple corner in the preview. Use Snap to grid or Align to Grid above the preview for 16-pixel alignment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func frameField(_ label: String, key: WritableKeyPath<WidgetFrame, Double>, dimension: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: Binding(
                get: { widget.frame[keyPath: key] * dimension },
                set: { value in store.changeGeometry(widget.id) { $0[keyPath: key] = value / dimension } }
            ), format: .number.precision(.fractionLength(0)))
            .textFieldStyle(.roundedBorder).accessibilityLabel("Widget \(label), in pixels")
        }
    }
}
