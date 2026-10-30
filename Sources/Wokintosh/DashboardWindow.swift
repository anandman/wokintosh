import AppKit

/// Presentation removes the title bar, but the dashboard still needs keyboard focus.
@MainActor final class DashboardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
