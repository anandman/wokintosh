import AppKit
import Combine
import SwiftUI

@main struct WokintoshMain {
    @MainActor static func main() {
        let application=NSApplication.shared
        guard AppInstanceGuard.canLaunch() else {return}
        let delegate=AppDelegate()
        application.delegate=delegate
        application.setActivationPolicy(delegate.store.document.showDockIcon ? .regular : .accessory)
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
    private let disconnectedDisplayMessage=AppMessage(title:"Display Disconnected",message:"Choose a connected presentation display in Display settings.")
    private var presentationDisplayUnavailable=false
    private enum FullscreenTransition { case entering, exiting }
    private struct PresentationRequest {
        var displayID:UInt32
        var nativeFullscreen:Bool
        var bringToFront:Bool
    }
    private var fullscreenTransition:FullscreenTransition?
    private var presentationRequest:PresentationRequest?
    private weak var presentationFocusWindow:NSWindow?
    private var pendingNativeFullscreen:Bool?
    private var nativePreferenceUpdateScheduled=false
    private var screenObserver:NSObjectProtocol?
    private var dockPreferenceSubscription:AnyCancellable?
    private var nativeFullscreenSubscription:AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        observeDisplayPreferences()
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
    func observeDisplayPreferences() {
        dockPreferenceSubscription = store.$document.map(\.showDockIcon).removeDuplicates().sink { [weak self] visible in
            self?.applyDockVisibility(visible)
        }
        nativeFullscreenSubscription = store.$document.map(\.nativeFullscreen).removeDuplicates().dropFirst().sink { [weak self] enabled in
            // @Published emits during willSet. Defer document mutations and keep the
            // emitted value so rapid changes reconcile to the latest preference.
            self?.pendingNativeFullscreen=enabled
            guard let self,!self.nativePreferenceUpdateScheduled else{return}
            self.nativePreferenceUpdateScheduled=true
            DispatchQueue.main.async { [weak self] in
                guard let self else{return}
                self.nativePreferenceUpdateScheduled=false
                guard let enabled=self.pendingNativeFullscreen else{return}
                self.pendingNativeFullscreen=nil
                guard var request=self.presentationRequest else{return}
                request.nativeFullscreen=enabled
                request.displayID=self.store.document.displayID ?? request.displayID
                request.bringToFront=false
                self.rememberPresentationFocus()
                self.presentationRequest=request
                self.reconcilePresentation()
            }
        }
    }
    private func applyDockVisibility(_ visible:Bool) {
        let policy:NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let wasActive=NSApp.isActive
        NSApp.setActivationPolicy(policy)
        if wasActive { NSApp.activate(ignoringOtherApps:true) }
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
        if !remember {
            store.document.presentationEnabled=false
            pendingMessages.removeAll{$0 == disconnectedDisplayMessage}
            presentationDisplayUnavailable=false
        }
        presentationRequest=nil
        dashboard?.presentationEscapeHandler=nil
        reconcilePresentation()
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
        requestPresentation(on:id,bringToFront:true)
    }
    private func requestPresentation(on id:UInt32?,bringToFront:Bool) {
        guard dashboard != nil else{return}
        let screen=id.flatMap { id in NSScreen.screens.first{screenID($0)==id} } ?? (id == nil ? NSScreen.main : nil)
        guard let screen,let id=screenID(screen) else{presentationDisplayDisconnected();return}
        presentationDisplayUnavailable=false
        pendingMessages.removeAll{$0 == disconnectedDisplayMessage}
        if bringToFront {presentationFocusWindow=nil}
        else {rememberPresentationFocus()}
        presentationRequest=PresentationRequest(displayID:id,nativeFullscreen:store.document.nativeFullscreen,bringToFront:bringToFront)
        if !store.document.presentationEnabled {store.document.presentationEnabled=true}
        if store.document.displayID != id {store.document.displayID=id}
        reconcilePresentation()
    }
    private func reconcilePresentation() {
        guard let window=dashboard,fullscreenTransition == nil else{return}
        guard var request=presentationRequest else {
            if window.styleMask.contains(.fullScreen) {beginFullscreenExit()}
            else {restoreWindowChrome();restorePresentationFocus()}
            return
        }
        guard let screen=NSScreen.screens.first(where:{screenID($0)==request.displayID}) else {
            presentationDisplayDisconnected();return
        }
        window.presentationEscapeHandler={ [weak self] in self?.leavePresentation() }
        if window.styleMask.contains(.fullScreen) {
            if request.nativeFullscreen && screenID(window.screen)==request.displayID {
                if request.bringToFront {window.makeKeyAndOrderFront(nil)}
                request.bringToFront=false;presentationRequest=request
                restorePresentationFocus()
            } else {beginFullscreenExit()}
            return
        }
        if request.nativeFullscreen {
            window.styleMask=[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView]
            window.collectionBehavior=[.fullScreenPrimary]
        } else {
            window.styleMask=[.borderless,.resizable]
            window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        }
        window.setFrame(screen.frame,display:true)
        if request.bringToFront {window.makeKeyAndOrderFront(nil)}
        else if !window.isVisible {window.orderFront(nil)}
        request.bringToFront=false;presentationRequest=request
        if request.nativeFullscreen {
            fullscreenTransition = .entering
            window.toggleFullScreen(nil)
        } else {restorePresentationFocus()}
    }
    private func beginFullscreenExit() {
        guard let window=dashboard else{return}
        fullscreenTransition = .exiting
        window.toggleFullScreen(nil)
    }
    private func rememberPresentationFocus() {
        if NSApp.isActive,let keyWindow=NSApp.keyWindow,keyWindow !== dashboard {presentationFocusWindow=keyWindow}
    }
    private func restorePresentationFocus() {
        guard fullscreenTransition == nil,let window=presentationFocusWindow else{return}
        // AppKit finishes choosing its key window after the fullscreen callback.
        DispatchQueue.main.async { [weak self,weak window] in
            guard let self,let window,self.fullscreenTransition == nil,self.presentationFocusWindow === window else{return}
            self.presentationFocusWindow=nil
            if NSApp.isActive,window.isVisible,NSApp.keyWindow == nil || NSApp.keyWindow === self.dashboard {window.makeKey()}
        }
    }
    private func presentationDisplayDisconnected() {
        suspendPresentation(remember:true)
        guard !presentationDisplayUnavailable else{return}
        presentationDisplayUnavailable=true
        store.settingsTab = .display
        if NSApp.isActive {enqueueMessage(disconnectedDisplayMessage)}
        else if activeMessage != disconnectedDisplayMessage,!pendingMessages.contains(disconnectedDisplayMessage) {pendingMessages.append(disconnectedDisplayMessage)}
    }
    private func screenID(_ screen:NSScreen?) -> UInt32? { (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
    func window(_ window:NSWindow,willUseFullScreenPresentationOptions proposed:NSApplication.PresentationOptions)->NSApplication.PresentationOptions {
        guard window === dashboard else{return proposed}
        return proposed.subtracting([.autoHideMenuBar,.autoHideDock,.autoHideToolbar]).union([.fullScreen,.hideMenuBar,.hideDock])
    }
    func windowWillEnterFullScreen(_ notification:Notification) {
        guard notification.object as? NSWindow === dashboard else{return}
        // The green window button can also initiate native fullscreen.
        if fullscreenTransition == nil,presentationRequest == nil,let id=screenID(dashboard?.screen) {
            presentationRequest=PresentationRequest(displayID:id,nativeFullscreen:true,bringToFront:false)
            store.document.presentationEnabled=true;store.document.displayID=id
            dashboard?.presentationEscapeHandler={ [weak self] in self?.leavePresentation() }
        }
        fullscreenTransition = .entering
    }
    func windowDidEnterFullScreen(_ notification:Notification) {
        guard notification.object as? NSWindow === dashboard else{return}
        fullscreenTransition=nil
        // AppKit can ignore a new toggle until its completion callback returns.
        DispatchQueue.main.async { [weak self] in self?.reconcilePresentation() }
    }
    func windowWillExitFullScreen(_ notification:Notification) {
        guard notification.object as? NSWindow === dashboard else{return}
        if fullscreenTransition != .exiting {
            // A system fullscreen exit is an explicit leave, not a mode change.
            presentationRequest=nil;store.document.presentationEnabled=false
        }
        fullscreenTransition = .exiting
    }
    func windowDidExitFullScreen(_ notification:Notification) {
        guard notification.object as? NSWindow === dashboard else{return}
        fullscreenTransition=nil
        // AppKit can ignore a new toggle until its completion callback returns.
        DispatchQueue.main.async { [weak self] in self?.reconcilePresentation() }
    }
    func windowDidFailToEnterFullScreen(_ window:NSWindow) {
        guard window === dashboard else{return}
        fullscreenTransition=nil
        if presentationRequest?.nativeFullscreen != true {reconcilePresentation();return}
        presentationRequest=nil;store.document.presentationEnabled=false
        restoreWindowChrome();restorePresentationFocus()
        store.openSettings(.display)
        enqueueMessage(AppMessage(title:"Could Not Enter Fullscreen",message:"Try Present again or turn off native fullscreen in Display settings.",isError:true))
    }
    func windowDidFailToExitFullScreen(_ window:NSWindow) {
        guard window === dashboard else{return}
        fullscreenTransition=nil
        restorePresentationFocus()
        // Do not retry automatically: AppKit has rejected this transition.
        enqueueMessage(AppMessage(title:"Could Not Leave Fullscreen",message:"Try leaving presentation again, then choose the fullscreen mode in Display settings.",isError:true))
    }
    func restorePresentationIfPossible() {
        guard store.document.presentationEnabled else{return}
        requestPresentation(on:store.document.displayID,bringToFront:false)
    }
    func applicationDidBecomeActive(_ notification:Notification) {presentNextMessage()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool { dashboard?.makeKeyAndOrderFront(nil);return true }
    func windowWillClose(_ notification:Notification) {
        if notification.object as? NSWindow === dashboard {suspendPresentation(remember:false)}
    }
    func applicationWillTerminate(_ notification:Notification) {store.saveNow()}
}
