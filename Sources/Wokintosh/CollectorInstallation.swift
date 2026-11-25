import Combine
import Foundation
import WokintoshCore

enum CollectorInstallationTarget: Identifiable, Equatable {
    case localObserver
    case remote(RemoteHost)

    var id: String {
        switch self {
        case .localObserver: return "local"
        case .remote(let host): return host.id.uuidString
        }
    }
    var name: String {
        switch self {
        case .localObserver: return "This Mac"
        case .remote(let host): return host.name
        }
    }
}

struct CollectorInstallationOutcome: Equatable {
    var details: String
    var hasWarning = false
}

struct CollectorInstallationEntry: Identifiable {
    enum Status: Equatable {
        case queued
        case running(String)
        case completed(CollectorInstallationOutcome)
        case failed(String)
    }
    let target: CollectorInstallationTarget
    var status: Status = .queued
    var id: String { target.id }
}

/// Owned by the store so activity survives closing or switching Settings tabs.
@MainActor final class CollectorInstallationController: ObservableObject {
    typealias Progress = @MainActor @Sendable (String) -> Void
    @Published private(set) var entries: [CollectorInstallationEntry] = []
    @Published private(set) var isRunning = false
    private var runID = UUID()

    var activeIndex: Int? {
        entries.firstIndex { if case .running = $0.status { return true }; return false }
    }
    var activeTarget: CollectorInstallationTarget? { activeIndex.map { entries[$0].target } }
    var updatedCount: Int {
        entries.filter { if case .completed = $0.status { return true }; return false }.count
    }
    var failedCount: Int {
        entries.filter { if case .failed = $0.status { return true }; return false }.count
    }
    var warningCount: Int {
        entries.filter { if case .completed(let outcome) = $0.status { return outcome.hasWarning }; return false }.count
    }
    var finishedCount: Int { updatedCount + failedCount }
    var summary: String {
        if let index = activeIndex {
            return "Updating \(index + 1) of \(entries.count) · \(entries[index].target.name)"
        }
        var parts = ["\(updatedCount) \(updatedCount == 1 ? "machine" : "machines") updated"]
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if warningCount > 0 { parts.append("\(warningCount) with warnings") }
        return parts.joined(separator: " · ")
    }
    func entry(for id: String) -> CollectorInstallationEntry? { entries.first { $0.id == id } }

    func run(_ targets: [CollectorInstallationTarget],
             operation: @MainActor (CollectorInstallationTarget, @escaping Progress) async throws -> CollectorInstallationOutcome) async {
        guard !isRunning, !targets.isEmpty else { return }
        let token = UUID()
        runID = token
        entries = targets.map { CollectorInstallationEntry(target: $0) }
        isRunning = true
        defer { isRunning = false }
        for index in entries.indices {
            entries[index].status = .running("Preparing update…")
            do {
                let outcome = try await operation(entries[index].target) { [weak self] value in
                    guard let self, self.runID == token,
                          case .running = self.entries[index].status else { return }
                    self.entries[index].status = .running(value)
                }
                entries[index].status = .completed(outcome)
            } catch {
                entries[index].status = .failed(error.localizedDescription)
            }
        }
    }
}
