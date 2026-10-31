import SwiftUI
import WokintoshCore

struct AgentWidget: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget
    var actionsEnabled=true
    var body: some View {
        GeometryReader { geometry in
            let t=store.document.textScale
            let layout=AgentWidgetLayout(width:geometry.size.width,height:geometry.size.height,textScale:t)
            let wide=layout.singleLine
            let narrow=layout.narrow
            let rowHeight=layout.rowHeight
            let header=layout.headerHeight
            let capacity=layout.capacity
            let page=AgentPresentation.make(rows:store.rows(for:widget),capacity:capacity,showFinished:widget.showFinished)
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:8) {
                    Text(layout.compactSummary ? "\(page.attentionCount) need you" : "\(page.attentionCount) need you · \(page.doneCount) done · \(page.workingCount) working")
                        .font(retroFont((narrow ? 20 : 23)*t)).lineLimit(narrow && !layout.compactSummary ? 2 : 1)
                        .help("\(page.attentionCount) need you · \(page.doneCount) done · \(page.workingCount) working")
                    Spacer(minLength:0)
                    if page.doneCount>0 {
                        Button { store.reviewAllCompletions(for:widget) } label: { Label("Review Done",systemImage:"checkmark.circle") }
                            .labelStyle(.iconOnly).font(.system(size:24*t)).buttonStyle(.plain).foregroundStyle(Color.retroPurple)
                            .accessibilityLabel("Mark all Done sessions in this widget as reviewed").help("Mark all Done as reviewed")
                    }
                }.frame(height:header,alignment:.leading)
                if page.visible.isEmpty && capacity > 0 {
                    VStack(alignment:.leading,spacing:9) {
                        Text("No active sessions").font(retroFont(30*t))
                        Text(store.refreshing ? "Checking agent machines…" : "Open a session or connect another machine in the editor.").font(retroFont(21*t,bold:false))
                    }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
                } else {
                    ForEach(page.visible) { row in
                        agentRow(row,wide:wide,narrow:narrow,t:t).frame(height:rowHeight)
                            .background(row.completionPending ? Color.retroPurple.opacity(0.13) : .clear)
                            .overlay(alignment:.top) { Rectangle().fill(.black.opacity(0.35)).frame(height:0.8) }
                    }
                    Spacer(minLength:0)
                }
                HStack(spacing:10) {
                    if let overflow=page.overflowLabel {
                        Text(narrow ? "+\(page.hiddenCount) more" : overflow).font(retroFont(20*t))
                            .foregroundStyle(page.hiddenAttentionCount > 0 ? .orange : .primary)
                            .help(overflow).accessibilityLabel(overflow)
                    }
                    if store.offlineCount > 0 && !store.document.previewMode { Text("\(store.offlineCount) offline").font(retroFont(18*t)).foregroundStyle(.orange) }
                    Spacer(minLength:0)
                }.frame(height:layout.footerHeight).lineLimit(1)
            }.padding(.horizontal,narrow ? 8 : 12).padding(.top,3)
        }
    }
    @ViewBuilder func agentRow(_ row:SessionRow,wide:Bool,narrow:Bool,t:Double)->some View {
        HStack(spacing:wide ? 10 : 8) {
            if narrow {
                WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled,provider:row.session.provider,accessibilityName:"Open app for \(row.session.title)") {
                    ProviderMark(provider:row.session.provider).frame(width:28*t,height:28*t)
                }
                VStack(alignment:.leading,spacing:1) {
                    WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled,provider:row.session.provider) {
                        Text(shortTitle(row.session.title)).font(retroFont(25*t)).lineLimit(1).accessibilityLabel(row.session.title).frame(maxWidth:.infinity,alignment:.leading)
                    }
                    HStack(spacing:6) {
                        state(row,t:t,font:20)
                        Text(row.hostName).font(retroFont(18*t,bold:false)).lineLimit(1)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            } else {
                WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled,provider:row.session.provider) {
                    HStack(spacing:wide ? 10 : 8) {
                        ProviderMark(provider:row.session.provider).frame(width:28*t,height:28*t)
                            .accessibilityLabel(row.session.provider == "codex" ? "Codex" : "Claude Code")
                        if wide {
                            Text(shortTitle(row.session.title)).font(retroFont(25*t)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading).accessibilityLabel(row.session.title)
                            Text(row.hostName+(row.session.isHelper || row.session.parentId != nil ? " · Helper" : ""))
                                .font(retroFont(18*t,bold:false)).lineLimit(1).frame(width:104*t,alignment:.leading)
                        } else {
                            VStack(alignment:.leading,spacing:0) {
                                Text(shortTitle(row.session.title)).font(retroFont(25*t)).lineLimit(1).accessibilityLabel(row.session.title)
                                Text(metadata(row)).font(retroFont(18*t,bold:false)).lineLimit(1)
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
                state(row,t:t,font:22).frame(width:156*t,alignment:.leading)
            }
        }.contextMenu {
            if widget.action.kind != .none {
                Button("Open Configured Action") {if actionsEnabled {store.activateWidget(widget.id,provider:row.session.provider)}}
                    .disabled(!actionsEnabled || store.document.previewMode)
                Divider()
            }
            if store.isManuallyBlocked(row) {
                Button("Clear Manual Blocked") { store.clearManualBlocked(row) }
            } else if row.session.state != .blocked {
                Button("Mark Blocked") { store.markBlocked(row) }
            } else {
                Text("Clear the published goal status on its machine")
            }
        }.help("\(row.session.title)\n\(metadata(row))\n\(row.session.activity ?? row.session.state.label)\nLast activity: \(row.session.updatedAt.formatted(date:.abbreviated,time:.standard))")
    }
    func metadata(_ row:SessionRow)->String {
        let helper=row.session.isHelper || row.session.parentId != nil ? " · Helper" : ""
        return "\(row.session.provider == "codex" ? "Codex" : "Claude Code") · \(row.hostName)\(helper)"
    }
    func shortTitle(_ title:String)->String {
        title.count>20 ? String(title.prefix(20))+"…" : title
    }
    func state(_ row:SessionRow,t:Double,font:Double)->some View {
        HStack(spacing:6) {
            StatusDot(state:row.session.state,connected:row.connected).frame(width:12*t,height:12*t)
            Text(row.connected || row.session.state == .blocked ? row.session.state.label : "Offline").font(retroFont(font*t)).foregroundStyle(StatusDot(state:row.session.state,connected:row.connected).tint)
            if row.completionPending {
                Button { store.reviewCompletion(row) } label: {
                    Image(systemName:"checkmark.circle").font(.system(size:21*t))
                        .frame(width:30*t,height:30*t).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color.retroPurple).accessibilityLabel("Mark \(row.session.title) done as reviewed").help("Mark done as reviewed")
            }
        }.lineLimit(1)
    }

}
