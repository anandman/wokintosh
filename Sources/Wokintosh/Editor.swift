import AppKit
import SwiftUI
import WokintoshCore

/// The live editing preview inside the Dashboard settings workspace.
struct EditorView: View {
    @ObservedObject var store: DashboardStore
    @State private var actualSize = false
    @State private var calibration = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                Button("Align to Grid") { store.alignWidgetsToGrid() }
                    .help("Align all widgets to the 16-pixel dashboard grid")
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh dashboard preview")
                .disabled(store.refreshing)
            }
            .controlSize(.small)
            HStack {
                Toggle("Snap to grid", isOn: $store.document.snapToGrid)
                Spacer(minLength: 8)
                Toggle("Actual-size preview", isOn: $actualSize)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Text("Move widgets by their title bars. Drag a purple corner to resize.")
                .font(.caption).foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Target width: \(Int(store.document.previewWidthMM)) mm")
                        Slider(value: $calibration, in: 0.6...1.6)
                            .accessibilityLabel("Actual-size preview calibration")
                    }
                    Text("Match the preview width to a ruler, then check it from your usual viewing distance.")
                        .foregroundStyle(.secondary)
                }.font(.caption)
            }
        }
        .padding(12)
    }

    private var pointsPerMM: Double {
        guard let screen = NSScreen.main else { return 72 / 25.4 }
        let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let physical = CGDisplayScreenSize(screenID).width
        return physical > 0 ? screen.frame.width / physical : 72 / 25.4
    }
}
