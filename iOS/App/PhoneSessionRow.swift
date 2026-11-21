import SwiftUI
import WokintoshCore

struct PhoneSessionRow:View {
    @ObservedObject var store:PhoneStore
    let row:PublishedAgentRow
    var body:some View {
        let review=command(.reviewDone),mark=command(.markBlocked),clear=command(.clearManualBlocked)
        HStack(alignment:.center,spacing:0) {
            Button {store.open(row)} label: {PhoneSessionInformation(row:row,offline:store.snapshot.state == .offline).padding(10).frame(maxWidth:.infinity,alignment:.leading)}
                .buttonStyle(PhoneSessionButtonStyle())
            if let review {
                Button {Task {await store.perform(review)}} label: {
                    Image(systemName:"checkmark.circle").font(.system(size:23)).frame(width:44,height:44)
                }.buttonStyle(.plain).foregroundStyle(PhonePalette.purple)
                    .accessibilityLabel("Review Done: \(row.session.title)").disabled(store.performingAction)
            }
        }.background(row.completionPending ? PhonePalette.purple.opacity(0.10) : .clear)
            .contextMenu {
                if let mark {
                    Button("Mark Blocked") {Task {await store.perform(mark)}}.disabled(store.performingAction)
                }
                if let clear {
                    Button("Clear Manual Blocked",systemImage:"minus.circle") {Task {await store.perform(clear)}}.disabled(store.performingAction)
                }
                Button("Session details",systemImage:"info.circle") {store.showSessionDetails(row)}
            }
            .accessibilityActions {
                if let mark {Button("Mark Blocked") {Task {await store.perform(mark)}}}
                if let clear {Button("Clear Manual Blocked") {Task {await store.perform(clear)}}}
            }
    }
    private func command(_ action:AgentControlAction)->AgentControlCommand? {
        guard let publisher=store.snapshot.feed?.publisherID,let widget=store.selectedWidget,
              let controls=row.controls,controls.allowed.contains(action) else {return nil}
        return AgentControlCommand(publisherID:publisher,widgetID:widget.id,rowID:row.id,action:action,revision:controls.revision)
    }

}
struct PhoneSessionInformation:View {
    let row:PublishedAgentRow
    var offline=false
    var body:some View {
        HStack(alignment:.top,spacing:9) {
            PhoneProviderMark(provider:row.session.provider).frame(width:25,height:25).padding(.top,1)
            VStack(alignment:.leading,spacing:5) {
                Text(row.session.title).font(PhonePalette.font(20,bold:true,relativeTo:.headline)).lineLimit(2).fixedSize(horizontal:false,vertical:true)
                Text(row.hostName+" · "+(row.session.project.isEmpty ? "No project" : row.session.project))
                    .font(PhonePalette.font(14,relativeTo:.caption)).foregroundStyle(PhonePalette.secondary).lineLimit(2)
                HStack(spacing:5) {
                    Circle().fill(stateColor).frame(width:8,height:8).accessibilityHidden(true)
                    Text(row.completionPending ? "Done" : row.session.state.label).font(PhonePalette.font(14,bold:true,relativeTo:.caption)).foregroundStyle(stateColor)
                    if offline || !row.connected {Text("· Offline").font(.caption).foregroundStyle(PhonePalette.secondary)}
                    else if row.freshness(at:Date()) == .stale {Text("· Stale").font(.caption).foregroundStyle(PhonePalette.secondary)}
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.foregroundStyle(.black).accessibilityElement(children:.combine).privacySensitive()
    }
    private var stateColor:Color {
        if row.completionPending {return PhonePalette.purple}
        switch row.session.state {
        case .needsAttention,.blocked:return PhonePalette.attention
        case .working:return PhonePalette.working
        case .finished:return PhonePalette.purple
        default:return PhonePalette.secondary
        }
    }
}
