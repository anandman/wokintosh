import AppKit
import OSLog
import SwiftUI

/// Menu controls stay in the dashboard's canvas and window, including while presented.
struct DashboardMenu: NSViewRepresentable {
    var openSettings:()->Void
    func makeNSView(context:Context)->MenuView {MenuView(openSettings:openSettings)}
    func updateNSView(_ view:MenuView,context:Context) {view.openSettings=openSettings}
    static func dismantleNSView(_ view:MenuView,coordinator:()) {view.detach()}

    @MainActor final class MenuView:NSView {
        private static let logger=Logger(subsystem:"dev.wokintosh.dashboard",category:"DashboardMenu")
        private let menuID=String(UUID().uuidString.prefix(8))
        private let trigger=MenuButton(frame:.zero)
        private let panel=MenuPanel(frame:.zero)
        private var rows:[MenuRow]=[]
        private var isOpen=false
        private var selection:Int?
        private weak var previousResponder:NSResponder?
        private weak var attachedWindow:DashboardWindow?
        var openSettings:()->Void
        override var isFlipped:Bool {true}
        override var acceptsFirstResponder:Bool {true}

        init(openSettings:@escaping ()->Void) {
            self.openSettings=openSettings
            super.init(frame:.zero)
            trigger.setButtonType(.pushOnPushOff)
            trigger.image=ColorStripeMark.image
            trigger.isBordered=false;trigger.imagePosition = .imageOnly
            trigger.imageScaling = .scaleProportionallyDown
            trigger.target=self;trigger.action=#selector(toggleMenu)
            trigger.setAccessibilityRole(.menuButton)
            trigger.setAccessibilityLabel("Wokintosh menu")
            trigger.setAccessibilityExpanded(false)
            trigger.toolTip="Dashboard settings and Quit Wokintosh"
            addSubview(trigger)
            panel.isHidden=true
            panel.setAccessibilityElement(true)
            panel.setAccessibilityRole(.menu)
            panel.setAccessibilityLabel("Wokintosh menu")
            addSubview(panel)
            for (index,title,shortcut) in [(0,"Dashboard & Settings…","⌘,"),(1,"Quit Wokintosh","⌘Q")] {
                let row=MenuRow(title:title,target:self,action:#selector(chooseRow(_:)))
                row.tag=index;row.shortcut=shortcut
                row.setButtonType(.momentaryPushIn);row.isBordered=false
                row.setAccessibilityRole(.menuItem)
                row.setAccessibilityLabel(title)
                row.onHover={ [weak self] in self?.select(index) }
                panel.addSubview(row);rows.append(row)
            }
        }
        required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
        deinit {NotificationCenter.default.removeObserver(self)}

        override func layout() {
            super.layout()
            trigger.frame=NSRect(x:16,y:6.5,width:25,height:25)
            panel.frame=NSRect(x:16,y:37,width:348,height:86)
            rows[0].frame=NSRect(x:2,y:3,width:344,height:36)
            rows[1].frame=NSRect(x:2,y:47,width:344,height:36)
        }
        override func hitTest(_ point:NSPoint)->NSView? {
            let local=convert(point,from:superview)
            guard !isHidden,bounds.contains(local),isOpen || trigger.frame.contains(local) else {return nil}
            return super.hitTest(point)
        }
        override func mouseDown(with event:NSEvent) {
            if !panel.frame.contains(convert(event.locationInWindow,from:nil)) {setOpen(false)}
        }
        override func keyDown(with event:NSEvent) {
            if !handleKey(event) {super.keyDown(with:event)}
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else {return}
            attachedWindow=window as? DashboardWindow
            attachedWindow?.setTransientKeyHandler(owner:self) { [weak self] event in self?.handleKey(event) ?? false }
            let center=NotificationCenter.default
            center.addObserver(self,selector:#selector(lostFocus),name:NSWindow.didResignKeyNotification,object:window)
            center.addObserver(self,selector:#selector(lostFocus),name:NSApplication.didResignActiveNotification,object:NSApp)
        }
        func detach() {
            setOpen(false,restoreFocus:false)
            attachedWindow?.clearTransientKeyHandler(owner:self)
            attachedWindow=nil
            NotificationCenter.default.removeObserver(self)
        }
        @objc private func lostFocus() {setOpen(false,restoreFocus:false)}
        @objc private func toggleMenu() {setOpen(!isOpen)}
        private func setOpen(_ open:Bool,restoreFocus:Bool=true) {
            guard isOpen != open else {return}
            isOpen=open;panel.isHidden = !open
            trigger.state=open ? .on : .off
            trigger.setAccessibilityExpanded(open)
            select(nil)
            if open {
                previousResponder=window?.firstResponder
                window?.makeFirstResponder(self)
            } else {
                if restoreFocus,window?.firstResponder === self {window?.makeFirstResponder(previousResponder ?? trigger)}
                previousResponder=nil
            }
            let pid=ProcessInfo.processInfo.processIdentifier
            Self.logger.notice("menu=\(self.menuID,privacy:.public) event=\(open ? "canvas-open" : "canvas-close",privacy:.public) pid=\(pid)")
            NSAccessibility.post(element:trigger,notification:.valueChanged)
        }
        private func select(_ index:Int?) {
            selection=index
            for (offset,row) in rows.enumerated() {row.selected=offset==index}
        }
        private func handleKey(_ event:NSEvent)->Bool {
            guard isOpen,event.type == .keyDown,
                  event.modifierFlags.intersection([.command,.control,.option]).isEmpty else {return false}
            switch event.keyCode {
            case 53:setOpen(false)
            case 125:select(selection.map {($0+1)%rows.count} ?? 0)
            case 126:select(selection.map {($0+rows.count-1)%rows.count} ?? rows.count-1)
            case 48:
                let backwards=event.modifierFlags.contains(.shift)
                select(selection.map {($0+(backwards ? rows.count-1 : 1))%rows.count} ?? (backwards ? rows.count-1 : 0))
            case 36,49,76:choose(selection ?? 0)
            default:return false
            }
            return true
        }
        @objc private func chooseRow(_ sender:NSButton) {choose(sender.tag)}
        private func choose(_ index:Int) {
            setOpen(false)
            if index==0 {openSettings()} else {NSApp.terminate(nil)}
        }
    }

    class MenuButton:NSButton {
        override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
        override func accessibilityPerformPress()->Bool {
            guard isEnabled else {return false}
            performClick(nil);return true
        }
    }
    final class MenuPanel:NSView {
        override var isFlipped:Bool {true}
        override func draw(_ dirtyRect:NSRect) {
            NSColor(calibratedWhite:0.965,alpha:1).setFill();bounds.fill()
            NSColor.black.setStroke()
            let border=NSBezierPath(rect:bounds.insetBy(dx:0.75,dy:0.75));border.lineWidth=1.5;border.stroke()
            NSColor.gray.setFill();NSRect(x:8,y:42,width:bounds.width-16,height:1).fill()
        }
    }
    final class MenuRow:MenuButton {
        var shortcut=""
        var selected=false {didSet {needsDisplay=true}}
        var onHover:(()->Void)?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil))
        }
        override func mouseEntered(with event:NSEvent) {onHover?()}
        override func draw(_ dirtyRect:NSRect) {
            let highlighted=selected || (cell?.isHighlighted ?? false)
            if highlighted {NSColor(calibratedRed:0.37,green:0.32,blue:0.91,alpha:1).setFill();bounds.fill()}
            let attributes:[NSAttributedString.Key:Any]=[.font:NSFont(name:"Geneva-Bold",size:20) ?? NSFont.boldSystemFont(ofSize:20),.foregroundColor:highlighted ? NSColor.white : NSColor.black]
            let label=title as NSString,key=shortcut as NSString
            let labelSize=label.size(withAttributes:attributes),keySize=key.size(withAttributes:attributes)
            label.draw(at:NSPoint(x:10,y:(bounds.height-labelSize.height)/2),withAttributes:attributes)
            key.draw(at:NSPoint(x:bounds.width-10-keySize.width,y:(bounds.height-keySize.height)/2),withAttributes:attributes)
        }
    }
}
