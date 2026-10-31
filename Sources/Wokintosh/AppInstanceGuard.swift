import AppKit
import WokintoshCore

/// Check before constructing DashboardStore so another copy cannot save stale settings.
@MainActor enum AppInstanceGuard {
    static func canLaunch()->Bool {
        let apps=NSWorkspace.shared.runningApplications.filter {!$0.isTerminated}
        let copies=AppInstancePolicy.otherCopies(currentPID:ProcessInfo.processInfo.processIdentifier,bundleID:Bundle.main.bundleIdentifier,running:apps.map {
            RunningAppInstance(pid:$0.processIdentifier,bundleID:$0.bundleIdentifier,path:$0.bundleURL?.path,launchedAt:$0.launchDate)
        })
        guard let first=copies.first else {return true}
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps:true)
        let alert=NSAlert();alert.messageText="Wokintosh is already running"
        var text=copies.count>1
            ? "There are \(copies.count) other copies running. Quit older copies first and your current copy last, so its latest dashboard is saved. Then open this version again."
            : "Quit the existing copy before opening this version. This keeps two copies from changing the same dashboard settings."
        let locations=copies.compactMap(\.path)
        if !locations.isEmpty {text+="\n\n"+locations.joined(separator:"\n")}
        alert.informativeText=text
        alert.addButton(withTitle:copies.count>1 ? "Show Older Copy":"Show Running Copy")
        alert.addButton(withTitle:"Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let existing=apps.first(where:{$0.processIdentifier==first.pid}) {
            existing.activate(options:[.activateAllWindows,.activateIgnoringOtherApps])
        }
        return false
    }
}
