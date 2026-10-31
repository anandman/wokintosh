import AppKit
import SwiftUI
import WokintoshCore

struct EditorView: View {
    @ObservedObject var store: DashboardStore
    @State private var actualSize = false
    @State private var calibration = 1.0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Layout Editor").font(.title2.bold())
                    Spacer()
                    Toggle("Actual-size preview", isOn: $actualSize).toggleStyle(.switch).fixedSize()
                    Button { Task { await store.refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }.disabled(store.refreshing)
                }
                Text("Move a widget by its title bar. Drag its purple corner to resize. Use Configure for its content and exact size.")
                    .foregroundStyle(.secondary)
                GeometryReader { geometry in
                    let fit = min(geometry.size.width, geometry.size.height * 16 / 9)
                    let width = actualSize ? min(fit, store.document.previewWidthMM * pointsPerMM * calibration) : fit
                    DashboardCanvas(store: store, editing: true)
                        .frame(width: width, height: width * 9 / 16)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if actualSize {
                    HStack {
                        Text("Target width: \(Int(store.document.previewWidthMM)) mm")
                        Slider(value: $calibration, in: 0.6...1.6).frame(width: 200)
                            .accessibilityLabel("Actual-size preview calibration")
                        Text("Match the preview width to a ruler, then judge it from your usual viewing distance.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let notice = store.notice {
                    Text(notice).font(.callout).foregroundStyle(.orange).textSelection(.enabled).lineLimit(3)
                }
                HStack {
                    Text(store.document.previewMode ? "Preview • fictional sessions and readings" : "Live • local and connected machines")
                    Spacer()
                    Text("1280 × 720 • 5-inch target")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(18)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Widget Library").font(.headline).padding(.top, 16)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(WidgetKind.allCases) { kind in
                    Button { store.add(kind) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: kind.settingsSymbol).font(.title2)
                            Text(kind.title).font(.caption)
                        }.frame(maxWidth: .infinity, minHeight: 58)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Add \(kind.title) widget")
                }
            }
            Divider()
            Text("On This Dashboard").font(.headline)
            List(selection: $store.selectedID) {
                ForEach(store.document.widgets) { widget in
                    Label(widgetSettingsName(widget, in: store.document.widgets), systemImage: widget.kind.settingsSymbol)
                        .tag(widget.id)
                        .contextMenu { WidgetActions(store: store, widget: widget) }
                }
            }
            .listStyle(.sidebar)
            .padding(.horizontal, -12)
            .accessibilityLabel("Dashboard widgets")
            HStack {
                Button("Configure…") {
                    if let id = store.selectedID { store.configure(id) }
                }.disabled(store.selectedWidget == nil)
                Spacer()
                Button("Settings…") { store.openSettings(.widgets) }
                    .help("Open Settings")
            }.padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
        .frame(width: 252)
    }

    private var pointsPerMM: Double {
        guard let screen = NSScreen.main else { return 72 / 25.4 }
        let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let physical = CGDisplayScreenSize(screenID).width
        return physical > 0 ? screen.frame.width / physical : 72 / 25.4
    }
}
