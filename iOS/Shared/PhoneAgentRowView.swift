import SwiftUI
import WokintoshCore

struct PhoneAgentRowView:View {
    let row:PublishedAgentRow
    var offline=false
    var showFreshness=true
    let at:Date
    var body:some View {
        HStack(alignment:.top,spacing:8) {
            PhoneProviderMark(provider:row.session.provider).frame(width:22,height:22).padding(.top,1)
            VStack(alignment:.leading,spacing:3) {
                HStack(alignment:.firstTextBaseline,spacing:6) {
                    Text(row.session.title).font(PhonePalette.font(17,bold:true,relativeTo:.headline)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                    Text(row.completionPending ? "Done" : row.session.statusLabel).font(PhonePalette.font(12,bold:true,relativeTo:.caption)).foregroundStyle(stateColor).lineLimit(1)
                }
                HStack(spacing:4) {
                    Text(row.hostName+" · "+(row.session.project.isEmpty ? "No project" : row.session.project))
                        .foregroundStyle(.secondary).lineLimit(1)
                    if !showFreshness,let freshnessLabel {
                        Text(freshnessLabel).foregroundStyle(.orange).fixedSize(horizontal:true,vertical:false)
                    }
                }.font(.caption)

                if showFreshness && (offline || row.freshness(at:at) != .current) {
                    Text(row.freshness(at:at) == .offline ? "Source offline · last known state" : "Saved snapshot · last known state")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
        }.accessibilityElement(children:.combine).privacySensitive()
    }
    private var freshnessLabel:String? {
        if !row.connected || offline {return "Offline"}
        return row.freshness(at:at) == .stale ? "Stale" : nil
    }
    private var stateColor:Color {
        if row.completionPending {return PhonePalette.widgetPurple}
        switch row.session.state {
        case .needsAttention,.blocked:return PhonePalette.widgetAttention
        case .working:return PhonePalette.widgetWorking
        case .finished:return PhonePalette.widgetPurple
        default:return .secondary
        }
    }
}
