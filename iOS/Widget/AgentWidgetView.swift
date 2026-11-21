import SwiftUI
import WidgetKit
import WokintoshCore

/// WidgetKit supplies different content heights on iPad, iPhone and with larger text.
/// Prefer the most rows whose intrinsic height fits; the footer always keeps its space.
struct AgentWidgetContentView:View {
    let entry:AgentWidgetEntry
    let family:WidgetFamily
    @Environment(\.dynamicTypeSize) private var typeSize
    var body:some View {
        let limit=AgentWidgetLayout.size(for:family).capacity(accessibility:typeSize.isAccessibilitySize)
        ViewThatFits(in:.vertical) {
            ForEach(Array((1...limit).reversed()),id:\.self) {count in
                AgentWidgetCandidateView(entry:entry,family:family,maximumRows:count)
            }
            AgentWidgetCandidateView(entry:entry,family:family,maximumRows:1,showHeader:false)
            AgentWidgetCandidateView(entry:entry,family:family,maximumRows:0)
        }
    }
}

private struct AgentWidgetCandidateView:View {
    let entry:AgentWidgetEntry
    let family:WidgetFamily
    let maximumRows:Int
    var showHeader=true
    @Environment(\.dynamicTypeSize) private var typeSize
    var body:some View {
        if let agents=entry.widget?.agents,let publisherID=entry.publisherID,let widget=entry.widget {
            let size=AgentWidgetLayout.size(for:family)
            let presentation=PhoneWidgetPresentation(agents:agents,size:size,
                                                     accessibility:typeSize.isAccessibilitySize,connection:entry.connection,at:entry.date,maximumRows:maximumRows)
            VStack(alignment:.leading,spacing:4) {
                if showHeader {
                    HStack(alignment:.firstTextBaseline) {
                        Text(widget.name).font(.subheadline.bold()).lineLimit(1)
                        Spacer(minLength:4)
                        if presentation.attentionCount>0 {Text("\(presentation.attentionCount) need you").font(.caption.weight(.semibold)).foregroundStyle(.orange)}
                        else if entry.sample {Text("SAMPLE").font(.caption2.bold()).foregroundStyle(.secondary)}
                    }
                    Divider()
                }
                if presentation.rows.isEmpty {
                    Text(agents.totalCount>0 ? "Open session list" : (presentation.offline ? "Source unavailable" : (presentation.stale ? "Waiting for fresh data" : "No active sessions")))
                        .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
                } else {
                    if size.columns==2 {
                        Grid(horizontalSpacing:20,verticalSpacing:4) {
                            ForEach(Array(stride(from:0,to:presentation.rows.count,by:2)),id:\.self) {index in
                                GridRow(alignment:.top) {
                                    sessionLink(presentation.rows[index],publisherID:publisherID,widgetID:widget.id)
                                    if index+1<presentation.rows.count {
                                        sessionLink(presentation.rows[index+1],publisherID:publisherID,widgetID:widget.id)
                                    } else {Color.clear.gridCellUnsizedAxes([.horizontal,.vertical]).accessibilityHidden(true)}
                                }
                                if index+2<presentation.rows.count {Divider().gridCellColumns(2)}
                            }
                        }
                    } else {
                        ForEach(presentation.rows) {row in
                            sessionLink(row,publisherID:publisherID,widgetID:widget.id)
                            if row.id != presentation.rows.last?.id {Divider()}
                        }
                    }
                    Spacer(minLength:0)
                }
                HStack(spacing:5) {
                    Text(asOf(presentation)).lineLimit(1).layoutPriority(1)
                    Spacer(minLength:0)
                    if presentation.earlierDoneCount>0 {Text("Done · \(presentation.earlierDoneCount) unread").lineLimit(1)}
                    if presentation.hiddenCount>0 {Text("+\(presentation.hiddenCount)").accessibilityLabel("\(presentation.hiddenCount) more sessions")}
                }.font(.caption2).foregroundStyle(presentation.offline || presentation.stale ? .orange : .secondary)
            }.privacySensitive()
        } else {
            VStack(alignment:.leading,spacing:8) {
                Label("Wokintosh Agents",systemImage:"terminal").font(.headline)
                Text(entry.paired ? "Choose a published Agent widget." : (entry.connection == .authorizationRequired ? "Pair with your Mac again." : "Pair with Wokintosh on your Mac."))
                    .font(.subheadline).foregroundStyle(.secondary)
                Link("Open Wokintosh",destination:URL(string:"wokintosh://dashboard")!).font(.subheadline.weight(.semibold))
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
        }
    }
    private func sessionLink(_ row:PublishedAgentRow,publisherID:UUID,widgetID:UUID)->some View {
        Link(destination:PhoneRoute(publisherID:publisherID,widgetID:widgetID,rowID:row.id).url) {
            PhoneAgentRowView(row:row,offline:entry.connection == .offline,showFreshness:false,at:entry.date)
                .frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func asOf(_ p:PhoneWidgetPresentation)->String {
        let prefix=p.offline ? "Offline · " : (p.stale ? "Stale · " : "")
        guard let date=p.asOf else {return prefix+"Not yet updated"}
        let sameDay=Calendar.current.isDate(date,inSameDayAs:entry.date)
        return prefix+"As of "+date.formatted(date:sameDay ? .omitted : .abbreviated,time:.shortened)
    }
}

struct AgentWidgetEntryView:View {
    let entry:AgentWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body:some View {
        AgentWidgetContentView(entry:entry,family:family)
            .containerBackground(for:.widget) {Color(uiColor:.systemBackground)}
            .widgetURL(URL(string:"wokintosh://dashboard")!)
    }
}
