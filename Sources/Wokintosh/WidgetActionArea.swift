import SwiftUI
import WokintoshCore

/// Wrap only content without other controls, so playback and Review keep their own actions.
struct WidgetActionArea<Content:View>:View {
    @ObservedObject var store:DashboardStore
    let widget:DashboardWidget
    var enabled=true
    var provider:String?=nil
    var accessibilityName:String?=nil
    @ViewBuilder var content:()->Content
    var body:some View {
        if enabled && !store.document.previewMode && widget.action.kind != .none {
            Button {store.activateWidget(widget.id,provider:provider)} label: {
                content().contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityHint("Opens this widget’s configured app or link")
                .modifier(ActionAccessibilityName(name:accessibilityName))
        } else {content()}
    }
}
private struct ActionAccessibilityName:ViewModifier {
    let name:String?
    @ViewBuilder func body(content:Content)->some View {
        if let name {content.accessibilityLabel(name)} else {content}
    }
}
