import SwiftUI
import WokintoshCore

struct EarlierDoneView:View {
    @ObservedObject var store:DashboardStore
    let widgetID:UUID
    var actionsEnabled=true
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        TimelineView(.periodic(from:.now,by:15)) { context in
            let widget=store.document.widgets.first{$0.id == widgetID}
            let rows=widget.map{store.completionPresentation(for:$0,at:context.date).earlier} ?? []
            VStack(alignment:.leading,spacing:16) {
                Text("Earlier Done · \(rows.count) unread").font(.title2.bold())
                Text("These completions stay unread until you review them. Opening an app keeps the reminder.")
                    .foregroundStyle(.secondary)
                if rows.isEmpty {
                    ContentUnavailableView("No Earlier Done Notices",systemImage:"checkmark.circle",description:Text("New completions appear on the dashboard first."))
                } else {
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:12) {
                            ForEach(rows) {row in
                                VStack(alignment:.leading,spacing:6) {
                                    Text(row.session.title).font(.headline).textSelection(.enabled)
                                    Text("\(row.session.provider == "codex" ? "Codex" : "Claude Code") · \(row.hostName)").foregroundStyle(.secondary)
                                    Text("Completed \(row.session.updatedAt.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        if let widget,widget.action.kind != .none {
                                            Button("Open Configured App or Link") {store.activateWidget(widget.id,provider:row.session.provider)}
                                                .disabled(!actionsEnabled || store.document.previewMode)
                                        }
                                        Spacer()
                                        Button("Review") {store.reviewCompletion(row)}
                                            .accessibilityLabel("Mark \(row.session.title) done as reviewed")
                                    }
                                }.frame(maxWidth:.infinity,alignment:.leading)
                                Divider()
                            }
                        }.padding(.trailing,8)
                    }
                }
                HStack {
                    Button("Review All Earlier Done") {for row in rows {store.reviewCompletion(row)}}.disabled(rows.isEmpty)
                    Spacer()
                    Button("Close") {dismiss()}.keyboardShortcut(.cancelAction)
                }
            }.padding(24)
        }.frame(width:620,height:500)
            .foregroundStyle(.primary)
            .preferredColorScheme(NSApp.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? .dark : .light)
    }
}
