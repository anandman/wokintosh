import AppKit
import SwiftUI

struct SettingsInventoryItem: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let isSelected: Bool
}

/// A bounded native scroll area avoids a nested SwiftUI List competing with its enclosing Form.
/// Selection remains in the store; the bridge owns only native rows and wheel/keyboard handling.
struct SettingsInventoryScrollView: NSViewRepresentable {
    let identifier: String
    let accessibilityLabel: String
    let items: [SettingsInventoryItem]
    let onToggle: (String, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToggle: onToggle) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = InventoryNativeScrollView()
        scrollView.identifier = NSUserInterfaceItemIdentifier(identifier)
        scrollView.setAccessibilityIdentifier(identifier)
        scrollView.setAccessibilityLabel(accessibilityLabel)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalLineScroll = 44
        scrollView.drawsBackground = false
        let document = InventoryDocumentView(frame: NSRect(x: 0, y: 0, width: 240, height: 0))
        document.autoresizingMask = [.width]
        scrollView.documentView = document
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onToggle = onToggle
        scrollView.identifier = NSUserInterfaceItemIdentifier(identifier)
        scrollView.setAccessibilityIdentifier(identifier)
        scrollView.setAccessibilityLabel(accessibilityLabel)
        guard let document = scrollView.documentView as? InventoryDocumentView else { return }
        document.update(items: items, identifier: identifier, target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        scrollView.tile()
        let maxY = max(0, document.frame.height - scrollView.contentSize.height)
        if scrollView.contentView.bounds.minY > maxY {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    final class Coordinator: NSObject {
        var onToggle: (String, Bool) -> Void
        init(onToggle: @escaping (String, Bool) -> Void) { self.onToggle = onToggle }

        @objc func toggle(_ sender: InventoryCheckbox) {
            onToggle(sender.itemID, sender.state == .on)
        }
    }
}

private final class InventoryNativeScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let documentView else { return }
        if documentView.frame.width != contentSize.width {
            documentView.setFrameSize(NSSize(width: contentSize.width, height: documentView.frame.height))
        }
    }
}

final class InventoryCheckbox: NSButton {
    var itemID = ""
}

private final class InventoryDocumentView: NSView {
    override var isFlipped: Bool { true }
    private let rowHeight: CGFloat = 44
    private var items: [SettingsInventoryItem] = []
    private var inventoryIdentifier = ""
    private var checkboxes: [InventoryCheckbox] = []
    private var subtitles: [NSTextField] = []

    func update(items: [SettingsInventoryItem], identifier: String, target: AnyObject, action: Selector) {
        if inventoryIdentifier != identifier || self.items.map(\.id) != items.map(\.id) {
            subviews.forEach { $0.removeFromSuperview() }
            checkboxes = items.map { item in
                let button = InventoryCheckbox(frame: .zero)
                button.setButtonType(.switch)
                button.itemID = item.id
                button.identifier = NSUserInterfaceItemIdentifier("\(identifier).\(item.id)")
                button.setAccessibilityIdentifier("\(identifier).\(item.id)")
                button.cell?.lineBreakMode = .byTruncatingTail
                button.target = target
                button.action = action
                addSubview(button)
                return button
            }
            subtitles = items.map { _ in
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                label.textColor = .secondaryLabelColor
                label.lineBreakMode = .byTruncatingMiddle
                label.maximumNumberOfLines = 1
                addSubview(label)
                return label
            }
        }
        self.items = items
        inventoryIdentifier = identifier
        for (index, item) in items.enumerated() {
            let button = checkboxes[index]
            button.title = item.title
            button.state = item.isSelected ? .on : .off
            button.toolTip = item.subtitle.isEmpty ? item.title : "\(item.title) — \(item.subtitle)"
            button.setAccessibilityLabel(item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)")
            subtitles[index].stringValue = item.subtitle
            subtitles[index].toolTip = item.subtitle
        }
        setFrameSize(NSSize(width: frame.width, height: rowHeight * CGFloat(items.count)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for index in checkboxes.indices {
            let top = CGFloat(index) * rowHeight
            checkboxes[index].frame = NSRect(x: 6, y: top + 2, width: max(0, newSize.width - 12), height: 22)
            subtitles[index].frame = NSRect(x: 26, y: top + 24, width: max(0, newSize.width - 32), height: 16)
        }
    }
}
