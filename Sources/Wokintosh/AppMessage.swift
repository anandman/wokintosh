import AppKit

struct AppMessage: Equatable {
    enum Action:Equatable {case reviewCollectorUpdates}
    enum Receipt:Equatable {case collectorUpdates([String])}
    let title:String
    let message:String
    var isError=false
    var action:Action?
    var receipt:Receipt?
}

@MainActor extension AppMessage {
    func makeAlert()->NSAlert {
        let alert=NSAlert()
        alert.messageText=title;alert.informativeText=message
        alert.alertStyle=isError || action != nil ? .warning : .informational
        alert.addButton(withTitle:action == nil ? "OK" : "Review Updates…")
        if action != nil {
            alert.addButton(withTitle:"Later")
            alert.buttons.last?.keyEquivalent="\u{1b}"
        }
        return alert
    }
}
