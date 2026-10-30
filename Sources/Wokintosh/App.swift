import AppKit
import SwiftUI

@main struct WokintoshMain {
    @MainActor static func main() {
        let application=NSApplication.shared
        let delegate=AppDelegate()
        application.delegate=delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store=DashboardStore()
    var dashboard: NSWindow?
    var editor: NSWindow?
    private var screenObserver:NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        store.showEditor = { [weak self] in self?.openEditor() }
        store.presentDashboard = { [weak self] id in self?.present(on: id) }
        let window=NSWindow(contentRect: NSRect(x:0,y:0,width:1280,height:720), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        window.title="Wokintosh"
        window.identifier=NSUserInterfaceItemIdentifier("wokintosh-dashboard")
        window.contentView=NSHostingView(rootView: DashboardCanvas(store: store, editing: false))
        window.contentAspectRatio=NSSize(width:16,height:9)
        window.minSize=NSSize(width:640,height:360)
        window.isReleasedWhenClosed=false
        window.delegate=self
        window.center()
        window.makeKeyAndOrderFront(nil)
        dashboard=window
        NSApp.activate(ignoringOtherApps:true)
        store.start()
        if ProcessInfo.processInfo.arguments.contains("--editor") { openEditor() } else { restorePresentationIfPossible() }
        screenObserver=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.restorePresentationIfPossible() } }
    }
    func makeMenu() {
        let menu=NSMenu()
        let appItem=NSMenuItem(); menu.addItem(appItem)
        let appMenu=NSMenu(); appItem.submenu=appMenu
        appMenu.addItem(withTitle:"About Wokintosh",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Layout Editor…",action:#selector(editorAction),keyEquivalent:",").target=self
        appMenu.addItem(withTitle:"Present on Display",action:#selector(presentAction),keyEquivalent:"f").target=self
        let leave=appMenu.addItem(withTitle:"Leave Presentation",action:#selector(leavePresentation),keyEquivalent:"\u{1b}")
        leave.target=self;leave.keyEquivalentModifierMask=[]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Quit Wokintosh",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem();menu.addItem(editItem); let edit=NSMenu(title:"Edit");editItem.submenu=edit
        for (title,selector,key) in [("Undo",Selector(("undo:")),"z"),("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle:title,action:selector,keyEquivalent:key) }
        NSApp.mainMenu=menu
    }
    @objc func editorAction() { openEditor() }
    @objc func presentAction() { present(on:store.document.displayID) }
    @objc func leavePresentation() { suspendPresentation(remember:false) }
    func suspendPresentation(remember:Bool) {
        if !remember { store.document.presentationEnabled=false }
        guard let window=dashboard else{return}
        window.styleMask=[.titled,.closable,.miniaturizable,.resizable]
        window.collectionBehavior=[]
        window.setContentSize(NSSize(width:1280,height:720));window.center()
    }
    func openEditor() {
        if let editor { editor.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true);return }
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1450,height:950),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Wokintosh — Layout Editor"
        window.identifier=NSUserInterfaceItemIdentifier("wokintosh-editor")
        window.contentView=NSHostingView(rootView: EditorView(store:store))
        let available=NSScreen.screens.filter { (($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value) != store.document.displayID }
        let screen=available.max { $0.visibleFrame.width*$0.visibleFrame.height < $1.visibleFrame.width*$1.visibleFrame.height } ?? NSScreen.main
        if let frame=screen?.visibleFrame {
            let width=min(1450,frame.width*0.95),height=min(950,frame.height*0.93)
            window.setFrame(NSRect(x:frame.midX-width/2,y:frame.midY-height/2,width:width,height:height),display:false)
            window.minSize=NSSize(width:min(1000,frame.width),height:min(700,frame.height))
        } else {window.center()}
        window.isReleasedWhenClosed=false
        window.makeKeyAndOrderFront(nil);editor=window
    }
    func present(on id: UInt32?) {
        guard let window=dashboard else{return}
        let screen=NSScreen.screens.first{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)==id} ?? NSScreen.main
        guard let screen else{return}
        store.document.presentationEnabled=true
        store.document.displayID=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        window.styleMask=[.borderless,.resizable]
        window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        window.setFrame(screen.frame,display:true)
        window.makeKeyAndOrderFront(nil)
    }
    func restorePresentationIfPossible() {
        guard store.document.presentationEnabled else{return}
        if let id=store.document.displayID,NSScreen.screens.contains(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id}) { present(on:id) }
        else { suspendPresentation(remember:true);store.notice="The selected display is disconnected. Choose a presentation display in the editor.";openEditor() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool { dashboard?.makeKeyAndOrderFront(nil);return true }
    func applicationWillTerminate(_ notification:Notification) { store.saveNow() }
}
