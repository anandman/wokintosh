import AppKit
import SwiftUI

/// A native pull-down keeps the image label and Quit available in an accessory app.
struct DashboardMenu: NSViewRepresentable {
    var openSettings:()->Void
    func makeCoordinator()->Coordinator {Coordinator(openSettings:openSettings)}
    func makeNSView(context:Context)->NSPopUpButton {
        let button=NSPopUpButton(frame:.zero,pullsDown:true)
        button.isBordered=false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let menu=NSMenu();menu.autoenablesItems=false
        let label=NSMenuItem(title:"Wokintosh",action:nil,keyEquivalent:"")
        label.image=ColorStripeMark.image;label.isHidden=true
        menu.addItem(label)
        let settings=NSMenuItem(title:"Dashboard & Settings…",action:#selector(Coordinator.showSettings),keyEquivalent:",")
        settings.target=context.coordinator;settings.keyEquivalentModifierMask = .command
        menu.addItem(settings);menu.addItem(.separator())
        let quit=NSMenuItem(title:"Quit Wokintosh",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        quit.target=NSApp;quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
        button.menu=menu
        button.setAccessibilityLabel("Wokintosh menu")
        button.toolTip="Dashboard settings and Quit Wokintosh"
        return button
    }
    func updateNSView(_ nsView:NSPopUpButton,context:Context) {context.coordinator.openSettings=openSettings}
    final class Coordinator:NSObject {
        var openSettings:()->Void
        init(openSettings:@escaping ()->Void) {self.openSettings=openSettings}
        @objc func showSettings() {openSettings()}
    }
}
