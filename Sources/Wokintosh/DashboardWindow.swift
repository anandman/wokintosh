import AppKit

/// Presentation removes the title bar, but the dashboard still needs keyboard focus.
@MainActor final class DashboardWindow: NSWindow {
    var presentationEscapeHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let leavePresentation = presentationEscapeHandler {
            leavePresentation()
            return
        }
        super.sendEvent(event)
    }
}
