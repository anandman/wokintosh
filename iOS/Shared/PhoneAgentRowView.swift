import SwiftUI
import WokintoshCore

struct PhoneAgentRowView:View {
    let row:PublishedAgentRow
    var offline=false
    let at:Date
    var body:some View {
        HStack(alignment:.top,spacing:8) {
            Image(systemName:row.session.provider=="claude" ? "sparkle" : "terminal")
                .font(.system(size:17,weight:.semibold)).foregroundStyle(row.session.provider=="claude" ? .orange : .blue)
                .frame(width:20).padding(.top,2)
            VStack(alignment:.leading,spacing:3) {
                HStack(alignment:.firstTextBaseline,spacing:6) {
                    Text(row.session.title).font(.headline).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                    Text(row.completionPending ? "Done" : row.session.state.label).font(.caption.weight(.semibold)).foregroundStyle(stateColor).lineLimit(1)
                }
                Text(row.hostName+" · "+(row.session.project.isEmpty ? "No project" : row.session.project))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if offline || row.freshness(at:at) != .current {
                    Text(row.freshness(at:at) == .offline ? "Source offline · last known state" : "Saved snapshot · last known state")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
        }.accessibilityElement(children:.combine).privacySensitive()
    }
    private var stateColor:Color {
        if row.completionPending {return .purple}
        switch row.session.state {
        case .needsAttention,.blocked:return .orange
        case .working:return .green
        case .finished:return .purple
        default:return .secondary
        }
    }
}
