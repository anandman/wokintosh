import AppKit

/// Presentation removes the title bar, but the dashboard still needs keyboard focus.
@MainActor final class DashboardWindow: NSWindow {
    var presentationEscapeHandler: (() -> Void)?
    private weak var transientKeyOwner:AnyObject?
    private var transientKeyHandler:((NSEvent)->Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func setTransientKeyHandler(owner:AnyObject,_ handler:@escaping (NSEvent)->Bool) {
        transientKeyOwner=owner;transientKeyHandler=handler
    }
    func clearTransientKeyHandler(owner:AnyObject) {
        guard transientKeyOwner === owner else {return}
        transientKeyOwner=nil;transientKeyHandler=nil
    }
    override func sendEvent(_ event: NSEvent) {
        if transientKeyOwner != nil,transientKeyHandler?(event)==true {return}
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let leavePresentation = presentationEscapeHandler {
            leavePresentation()
            return
        }
        super.sendEvent(event)
    }
}
