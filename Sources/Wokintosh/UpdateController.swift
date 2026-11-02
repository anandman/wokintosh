import Combine
import Foundation
import Sparkle

struct UpdateState: Equatable {
    var canCheck = false
    var automaticallyChecks = false
    var automaticallyDownloads = false
    var lastCheck: Date?
    var availableVersion: String?
    var readyToInstall = false
    var issue: String?
    var unavailableReason: String?
}

@MainActor protocol UpdateDriving: AnyObject {
    var state: UpdateState { get }
    var onChange: (() -> Void)? { get set }
    func start() throws
    func checkForUpdates()
    func setAutomaticallyChecks(_ enabled: Bool)
    func setAutomaticallyDownloads(_ enabled: Bool)
}

/// Sparkle owns its preferences and scheduling; the UI observes one current snapshot.
@MainActor final class UpdateController: ObservableObject {
    @Published private(set) var state: UpdateState
    private let driver: any UpdateDriving
    private var started = false
    var canCheckForUpdates: Bool { started && state.canCheck }
    var menuTitle: String { state.availableVersion == nil ? "Check for Updates…" : "Update Available…" }

    convenience init(bundle: Bundle = .main) {
        // SwiftPM tests and ad hoc development bundles must not schedule real updates.
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        if bundle.bundleURL.pathExtension == "app",
           let key, Data(base64Encoded: key)?.count == 32,
           let feed, URL(string: feed)?.scheme == "https" {
            self.init(driver: SparkleUpdateDriver())
        } else {
            self.init(driver: UnconfiguredUpdateDriver())
        }
    }

    init(driver: any UpdateDriving) {
        self.driver = driver
        state = driver.state
        driver.onChange = { [weak self] in self?.refresh() }
    }
    func start() {
        guard !started else { return }
        do { try driver.start(); started = true; refresh() }
        catch { state.issue = error.localizedDescription }
    }
    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        driver.checkForUpdates()
        refresh()
    }
    func setAutomaticallyChecks(_ enabled: Bool) {
        driver.setAutomaticallyChecks(enabled)
        refresh()
    }
    func setAutomaticallyDownloads(_ enabled: Bool) {
        driver.setAutomaticallyDownloads(enabled)
        refresh()
    }
    private func refresh() { state = driver.state }
}

@MainActor private final class UnconfiguredUpdateDriver: UpdateDriving {
    let state = UpdateState(unavailableReason: "Automatic updates are available in signed release builds.")
    var onChange: (() -> Void)?
    func start() {}
    func checkForUpdates() {}
    func setAutomaticallyChecks(_ enabled: Bool) {}
    func setAutomaticallyDownloads(_ enabled: Bool) {}
}

@MainActor final class SparkleUpdateDriver: NSObject, UpdateDriving, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private var availableVersion: String?
    private var readyVersion: String?
    private var issue: String?
    var onChange: (() -> Void)?
    var sparkleUpdater: SPUUpdater { controller.updater }
    private var updater: SPUUpdater { sparkleUpdater }
    var state: UpdateState {
        UpdateState(canCheck: updater.canCheckForUpdates,
                    automaticallyChecks: updater.automaticallyChecksForUpdates,
                    automaticallyDownloads: updater.automaticallyDownloadsUpdates,
                    lastCheck: updater.lastUpdateCheckDate,
                    availableVersion: readyVersion ?? availableVersion,
                    readyToInstall: readyVersion != nil, issue: issue)
    }
    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        // KVO also catches choices made in Sparkle's own update dialog.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in self?.changed() },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in self?.changed() },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in self?.changed() },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in self?.changed() }
        ]
    }
    nonisolated private func changed() {
        Task { @MainActor [weak self] in self?.onChange?() }
    }
    func start() throws { try updater.start() }
    func checkForUpdates() { issue = nil; controller.checkForUpdates(nil) }
    func setAutomaticallyChecks(_ enabled: Bool) { updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticallyDownloads(_ enabled: Bool) { updater.automaticallyDownloadsUpdates = enabled }

    // Sparkle documents its standard UI callbacks as main-thread-only; its
    // Objective-C user-driver protocol does not yet annotate that isolation.
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip {
            // Sparkle cancels a prepared installer when the user skips the update.
            readyVersion = nil
            availableVersion = nil
            onChange?()
        }
    }
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Scheduled alerts are represented by the visible dashboard/menu/Settings reminder.
        // User-initiated checks still use Sparkle's standard install/relaunch UI.
        false
    }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        issue = nil
        onChange?()
    }
    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        onChange?()
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        readyVersion = item.displayVersionString
        issue = nil
        onChange?()
        return false // Keep Sparkle's scheduler and install-on-quit behavior.
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue {
            issue = nil
            availableVersion = nil
        } else {
            if error.domain == SUSparkleErrorDomain && (4000..<5000).contains(error.code) {
                // Installation-phase failures invalidate readiness; a transient
                // feed/download error must not discard an already prepared update.
                readyVersion = nil
                availableVersion = nil
            }
            issue = error.localizedDescription
        }
        onChange?()
    }
}
