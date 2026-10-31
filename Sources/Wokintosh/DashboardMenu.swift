import AppKit
import OSLog
import SwiftUI

/// Open a native menu after a complete click, without a pull-down cell's tracking state.
struct DashboardMenu: NSViewRepresentable {
    var openSettings:()->Void
    func makeCoordinator()->Coordinator {Coordinator(openSettings:openSettings)}
    func makeNSView(context:Context)->MenuButton {
        let button=MenuButton(frame:.zero)
        button.setButtonType(.momentaryPushIn)
        button.image=ColorStripeMark.image
        button.target=context.coordinator
        button.action=#selector(Coordinator.showMenu(_:))
        button.sendAction(on:.leftMouseUp)
        button.isBordered=false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        let menu=NSMenu();menu.autoenablesItems=false
        let settings=NSMenuItem(title:"Dashboard & Settings…",action:#selector(Coordinator.showSettings),keyEquivalent:",")
        settings.target=context.coordinator;settings.keyEquivalentModifierMask = .command
        menu.addItem(settings);menu.addItem(.separator())
        let quit=NSMenuItem(title:"Quit Wokintosh",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        quit.target=NSApp;quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
        menu.delegate=context.coordinator
        button.menu=menu
        context.coordinator.attach(button,menu:menu)
        button.setAccessibilityRole(.menuButton)
        button.setAccessibilityLabel("Wokintosh menu")
        button.toolTip="Dashboard settings and Quit Wokintosh"
        return button
    }
    func updateNSView(_ nsView:MenuButton,context:Context) {
        context.coordinator.openSettings=openSettings
        context.coordinator.didUpdate()
    }
    static func dismantleNSView(_ nsView:MenuButton,coordinator:Coordinator) {coordinator.dismantle()}

    final class MenuButton:NSButton {
        override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    }

    @MainActor final class Coordinator:NSObject,NSMenuDelegate {
        private static let logger=Logger(subsystem:"dev.wokintosh.dashboard",category:"DashboardMenu")
        private let menuID=String(UUID().uuidString.prefix(8))
        private weak var button:NSButton?
        private var menu:NSMenu?
        private var trackingStarted:TimeInterval?
        private var updatesWhileOpen=0
        private var focusChangesWhileOpen=0
        var openSettings:()->Void
        init(openSettings:@escaping ()->Void) {self.openSettings=openSettings}
        deinit {NotificationCenter.default.removeObserver(self)}

        func attach(_ button:NSButton,menu:NSMenu) {self.button=button;self.menu=menu;record("make")}
        @objc func showMenu(_ sender:NSButton) {
            guard let menu else {return}
            // The click has finished before tracking starts. Clear the momentary
            // highlight now and on return, including outside-click dismissal.
            sender.highlight(false);sender.state = .off
            defer {sender.highlight(false);sender.state = .off}
            record("click-release")
            sender.window?.makeKeyAndOrderFront(nil)
            if !NSApp.isActive {NSApp.activate(ignoringOtherApps:true)}
            let below=NSPoint(x:sender.bounds.minX,y:sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY)
            menu.popUp(positioning:nil,at:below,in:sender)
        }
        func didUpdate() {
            guard trackingStarted != nil else {return}
            updatesWhileOpen+=1
            // One update notice per open; the close notice carries the full count.
            if updatesWhileOpen==1 {record("first-update-while-open")}
        }
        func dismantle() {
            record("dismantle")
            NotificationCenter.default.removeObserver(self)
            trackingStarted=nil
            button=nil
        }
        func menuWillOpen(_ menu:NSMenu) {
            NotificationCenter.default.removeObserver(self)
            trackingStarted=ProcessInfo.processInfo.systemUptime
            updatesWhileOpen=0;focusChangesWhileOpen=0
            record("open")
            let center=NotificationCenter.default
            if let window=button?.window {
                for name in [NSWindow.didResignKeyNotification,NSWindow.didBecomeKeyNotification] {
                    center.addObserver(self,selector:#selector(focusChanged(_:)),name:name,object:window)
                }
            }
            for name in [NSApplication.didResignActiveNotification,NSApplication.didBecomeActiveNotification] {
                center.addObserver(self,selector:#selector(focusChanged(_:)),name:name,object:NSApp)
            }
        }
        func menuDidClose(_ menu:NSMenu) {
            record("close")
            NotificationCenter.default.removeObserver(self)
            trackingStarted=nil
        }
        @objc private func focusChanged(_ notification:Notification) {
            guard trackingStarted != nil else {return}
            focusChangesWhileOpen+=1
            // Bound diagnostics even if another app repeatedly takes keyboard focus.
            guard focusChangesWhileOpen<=4 else {return}
            switch notification.name {
            case NSWindow.didResignKeyNotification:record("parent-resigned-key")
            case NSWindow.didBecomeKeyNotification:record("parent-became-key")
            case NSApplication.didResignActiveNotification:record("app-resigned-active")
            default:record("app-became-active")
            }
        }
        private func record(_ event:String) {
            let elapsed=trackingStarted.map {ProcessInfo.processInfo.systemUptime-$0} ?? 0
            let active=NSApp.isActive,key=button?.window?.isKeyWindow ?? false
            let pid=ProcessInfo.processInfo.processIdentifier
            // Metadata only, stored locally by unified logging; no dashboard content.
            Self.logger.notice("menu=\(self.menuID,privacy:.public) event=\(event,privacy:.public) pid=\(pid) active=\(active) parentKey=\(key) open=\(self.trackingStarted != nil) elapsed=\(elapsed) updates=\(self.updatesWhileOpen) focusChanges=\(self.focusChangesWhileOpen)")
        }
        @objc func showSettings() {openSettings()}
    }
}
