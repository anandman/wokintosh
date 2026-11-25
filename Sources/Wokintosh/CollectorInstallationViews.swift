import SwiftUI

struct CollectorInstallationActivityView: View {
    @ObservedObject var installation: CollectorInstallationController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if installation.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: installation.failedCount > 0 || installation.warningCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(installation.failedCount > 0 ? Color.red : installation.warningCount > 0 ? Color.orange : Color.green)
                }
                Text(installation.summary).font(.headline)
            }
            if let index = installation.activeIndex,
               case .running(let stage) = installation.entries[index].status {
                Text(stage).font(.caption)
                ProgressView(value: Double(installation.finishedCount), total: Double(installation.entries.count))
                    .accessibilityLabel(installation.summary)
            }
            if !installation.isRunning, installation.failedCount > 0 {
                ForEach(installation.entries) { entry in
                    if case .failed(let details) = entry.status {
                        Text("\(entry.target.name): \(details)")
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
        }.padding(.vertical, 4)
    }
}

struct CollectorInstallationStatusView: View {
    let entry: CollectorInstallationEntry

    var body: some View {
        switch entry.status {
        case .queued:
            Label("Waiting to update", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        case .running(let stage):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Updating… \(stage)").font(.caption)
            }.accessibilityElement(children: .combine)
        case .completed(let outcome):
            VStack(alignment: .leading, spacing: 4) {
                Label(outcome.hasWarning ? "Updated with warnings" : "Updated", systemImage: outcome.hasWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(outcome.hasWarning ? Color.orange : Color.green)
                DisclosureGroup("Details") {
                    Text(outcome.details).textSelection(.enabled)
                }.font(.caption)
            }
        case .failed(let details):
            VStack(alignment: .leading, spacing: 4) {
                Label("Update failed", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(details).textSelection(.enabled)
            }.font(.caption)
        }
    }
}
