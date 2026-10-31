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
    var dashboard: DashboardWindow?
    var settings: NSWindow?
    private var pendingMessages:[AppMessage]=[]
    private var activeMessage:AppMessage?
    private var transitioning=false
    private var resumeAfterExit=false
    private var pendingDisplayID:UInt32?
    private var exitRequested=false
    private var preservePreference=false
    private var screenObserver:NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        store.showEditor = { [weak self] in self?.openEditor() }
        store.showSettings = { [weak self] in self?.openSettings() }
        store.presentMessage = { [weak self] message in self?.enqueueMessage(message) }
        store.presentDashboard = { [weak self] id in self?.present(on: id) }
        let window=DashboardWindow(contentRect: NSRect(x:0,y:0,width:1280,height:720), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        window.title="Wokintosh"
        window.identifier=NSUserInterfaceItemIdentifier("wokintosh-dashboard")
        window.contentView=NSHostingView(rootView: DashboardCanvas(store: store, editing: false).ignoresSafeArea())
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
        appMenu.addItem(withTitle:"Dashboard & Settings…",action:#selector(settingsAction),keyEquivalent:",").target=self
        let layoutEditor=appMenu.addItem(withTitle:"Edit Dashboard…",action:#selector(editorAction),keyEquivalent:"l")
        layoutEditor.target=self;layoutEditor.keyEquivalentModifierMask=[.command,.shift]
        appMenu.addItem(withTitle:"Present on Display",action:#selector(presentAction),keyEquivalent:"f").target=self
        let leave=appMenu.addItem(withTitle:"Leave Presentation",action:#selector(leavePresentation),keyEquivalent:"\u{1b}")
        leave.target=self;leave.keyEquivalentModifierMask=[]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Quit Wokintosh",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem();menu.addItem(editItem); let edit=NSMenu(title:"Edit");editItem.submenu=edit
        for (title,selector,key) in [("Undo",Selector(("undo:")),"z"),("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle:title,action:selector,keyEquivalent:key) }
        NSApp.mainMenu=menu
    }
    @objc func settingsAction() { store.openSettings(store.settingsTab) }
    @objc func editorAction() { openEditor() }
    @objc func presentAction() { present(on:store.document.displayID) }
    @objc func leavePresentation() { suspendPresentation(remember:false) }
    func suspendPresentation(remember:Bool) {
        if !remember { store.document.presentationEnabled=false }
        preservePreference=remember;resumeAfterExit=false
        guard let window=dashboard else{return}
        window.presentationEscapeHandler=nil
        if transitioning { exitRequested=true;return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        else { restoreWindowChrome() }
    }
    private func restoreWindowChrome() {
        guard let window=dashboard else{return}
        window.presentationEscapeHandler=nil
        window.styleMask=[.titled,.closable,.miniaturizable,.resizable]
        window.collectionBehavior=[]
        window.setContentSize(NSSize(width:1280,height:720));window.center()
    }
    func openEditor() { store.openSettings(.widgets) }
    private func enqueueMessage(_ message:AppMessage) {
        guard activeMessage != message,!pendingMessages.contains(message) else { return }
        pendingMessages.append(message)
        presentNextMessage()
    }
    private func presentNextMessage() {
        guard activeMessage == nil,!pendingMessages.isEmpty else { return }
        activeMessage=pendingMessages.removeFirst()
        guard let message=activeMessage else { return }
        openSettings()
        guard let settings else { activeMessage=nil;return }
        let alert=NSAlert()
        alert.messageText=message.title;alert.informativeText=message.message
        alert.alertStyle=message.isError ? .warning : .informational
        alert.addButton(withTitle:"OK")
        alert.beginSheetModal(for:settings) { [weak self] _ in
            Task { @MainActor in self?.activeMessage=nil;self?.presentNextMessage() }
        }
    }
    func openSettings() {
        if let settings { settings.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return }
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1560,height:920),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Wokintosh — Dashboard & Settings"
        window.identifier=NSUserInterfaceItemIdentifier("wokintosh-settings")
        window.contentView=NSHostingView(rootView:SettingsView(store:store))
        window.minSize=NSSize(width:1050,height:720)
        window.tabbingMode = .disallowed
        let available=NSScreen.screens.filter { screenID($0) != store.document.displayID }
        let screen=available.max { $0.visibleFrame.width*$0.visibleFrame.height < $1.visibleFrame.width*$1.visibleFrame.height } ?? NSScreen.main
        if let frame=screen?.visibleFrame {
            let width=min(1560,frame.width*0.95),height=min(920,frame.height*0.93)
            window.setFrame(NSRect(x:frame.midX-width/2,y:frame.midY-height/2,width:width,height:height),display:false)
        } else { window.center() }
        window.isReleasedWhenClosed=false
        settings=window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func present(on id:UInt32?) {
        guard let window=dashboard else{return}
        let screen=NSScreen.screens.first{screenID($0)==id} ?? NSScreen.main
        guard let screen else{return}
        if transitioning {pendingDisplayID=screenID(screen);resumeAfterExit=true;return}
        if window.styleMask.contains(.fullScreen) {
            if store.document.nativeFullscreen && screenID(window.screen)==screenID(screen) {window.makeKeyAndOrderFront(nil);return}
            pendingDisplayID=screenID(screen);resumeAfterExit=true;preservePreference=true
            window.toggleFullScreen(nil);return
        }
        store.document.presentationEnabled=true
        store.document.displayID=screenID(screen)
        preservePreference=false;exitRequested=false
        window.presentationEscapeHandler={ [weak self] in self?.leavePresentation() }
        if store.document.nativeFullscreen {
            window.styleMask=[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView]
            window.collectionBehavior=[.fullScreenPrimary]
            window.setFrame(screen.frame,display:true)
            window.makeKeyAndOrderFront(nil)
            transitioning=true
            window.toggleFullScreen(nil)
        } else {
            window.styleMask=[.borderless,.resizable]
            window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            window.setFrame(screen.frame,display:true);window.makeKeyAndOrderFront(nil)
        }
    }
    private func screenID(_ screen:NSScreen?) -> UInt32? { (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
    func window(_ window:NSWindow,willUseFullScreenPresentationOptions proposed:NSApplication.PresentationOptions)->NSApplication.PresentationOptions {
        guard window === dashboard else{return proposed}
        return proposed.subtracting([.autoHideMenuBar,.autoHideDock,.autoHideToolbar]).union([.fullScreen,.hideMenuBar,.hideDock])
    }
    func windowWillEnterFullScreen(_ notification:Notification) {if notification.object as? NSWindow === dashboard {transitioning=true}}
    func windowDidEnterFullScreen(_ notification:Notification) {
        guard notification.object as? NSWindow === dashboard else{return}
        transitioning=false
        if exitRequested {exitRequested=false;suspendPresentation(remember:preservePreference);return}
        store.document.presentationEnabled=true
        if resumeAfterExit {resumeAfterExit=false;present(on:pendingDisplayID)}
    }
    func windowWillExitFullScreen(_ notification:Notification) {if notification.object as? NSWindow === dashboard {transitioning=true}}
    func windowDidExitFullScreen(_ notification:Notification) {
        guard notification.object as? NSWindow === dashboard else{return}
        transitioning=false;exitRequested=false
        restoreWindowChrome()
        if resumeAfterExit {resumeAfterExit=false;present(on:pendingDisplayID)}
        else {if !preservePreference {store.document.presentationEnabled=false};preservePreference=false}
    }
    func windowDidFailToEnterFullScreen(_ window:NSWindow) {
        guard window === dashboard else{return}
        transitioning=false;resumeAfterExit=false;exitRequested=false;store.document.presentationEnabled=false
        restoreWindowChrome();store.openSettings(.display);enqueueMessage(AppMessage(title:"Could Not Enter Fullscreen",message:"Try Present again or turn off native fullscreen in Display settings.",isError:true))
    }
    func restorePresentationIfPossible() {
        guard store.document.presentationEnabled else{return}
        if let id=store.document.displayID,NSScreen.screens.contains(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id}) { present(on:id) }
        else { suspendPresentation(remember:true);store.openSettings(.display);enqueueMessage(AppMessage(title:"Display Disconnected",message:"Choose a connected presentation display in Display settings.")) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool { dashboard?.makeKeyAndOrderFront(nil);return true }
    func applicationWillTerminate(_ notification:Notification) { store.saveNow() }
}
