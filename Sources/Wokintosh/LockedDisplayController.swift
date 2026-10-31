import AppKit

/// Public login-window visibility request, scoped to the presented dashboard.
/// AppKit does not promise visibility on the current macOS lock screen.
@MainActor final class LockedDisplayController {
    private weak var window: NSWindow?
    private var enabled = false
    private var presentationActive = false

    init(window: NSWindow) {
        self.window = window
        apply()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        apply()
    }

    func setPresentationActive(_ active: Bool) {
        presentationActive = active
        apply()
    }

    private func apply() {
        window?.canBecomeVisibleWithoutLogin = enabled && presentationActive
    }
}
