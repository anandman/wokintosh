import SwiftUI
import WokintoshCore

struct BackgroundTaskSheet:View {
    @ObservedObject var store:DashboardStore
    let widgetID:UUID
    let rowID:String
    @Environment(\.dismiss) private var dismiss
    @State private var error:String?
    private var row:SessionRow? {
        guard let widget=store.document.widgets.first(where:{$0.id==widgetID}) else {return nil}
        return store.rows(for:widget).first(where:{$0.id==rowID})
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Stripes();Text("Background Tasks").font(barFont()).lineLimit(1).fixedSize();Stripes()
            }.padding(8).background(Color(white:0.88)).overlay(Rectangle().stroke(.black,lineWidth:1))
            if let row {
                HStack(spacing:10) {
                    ProviderMark(provider:row.session.provider).frame(width:28,height:28)
                    VStack(alignment:.leading,spacing:3) {
                        Text(row.session.title).font(retroFont(21))
                        Text(row.hostName+" · "+row.session.statusLabel).font(retroFont(15,bold:false)).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:15) {
                        ForEach(row.session.background?.tasks ?? []) {task in taskView(task,row:row);Divider()}
                    }
                }
                if row.session.background?.tasks.isEmpty != false {Text("No tracked background tasks. Update this machine’s collector if tasks are missing.").foregroundStyle(.secondary)}
                if !row.connected {Text("Source offline. Reconnect before changing a task’s role.").foregroundStyle(.secondary)}
            } else {Text("This session is no longer on this dashboard.").foregroundStyle(.secondary)}
            Text("Work keeps a session Working. Monitor allows Monitoring between active turns. Automatic uses the provider’s task type. Choices apply to this task run; they don’t start or stop it.")
                .font(retroFont(14,bold:false)).fixedSize(horizontal:false,vertical:true)
            if let error {Text(error).foregroundStyle(.red).font(.callout)}
            HStack {Spacer();Button("Done") {dismiss()}.keyboardShortcut(.defaultAction)}
        }.padding(20).frame(width:560,height:510).background(Color.retroPaper).foregroundStyle(.black).preferredColorScheme(.light)
    }
    private func taskView(_ task:WokintoshCore.BackgroundTask,row:SessionRow)->some View {
        VStack(alignment:.leading,spacing:7) {
            Text(task.label).font(retroFont(17)).textSelection(.enabled)
            Text(task.kind.capitalized+" · "+(task.status.isActive && !task.isVerified(at:Date()) ? "Unverified" : task.status.label)+" · "+task.id)
                .font(retroFont(13,bold:false)).foregroundStyle(.secondary).textSelection(.enabled)
            if task.status.isActive {
                Picker("Treat as",selection:Binding(get:{store.backgroundTaskRoles.role(for:task,rowID:row.id)},set:{role in
                    do {try store.setBackgroundTaskRole(role,taskID:task.id,row:row);error=nil}
                    catch {self.error=error.localizedDescription}
                })) {
                    ForEach(BackgroundTaskRole.allCases) {role in Text(role.title).tag(role)}
                }.pickerStyle(.segmented).disabled(!row.connected || store.document.previewMode)
                    .accessibilityLabel("Role for \(task.label)")
                Text("Automatic: \(task.kind == "monitor" ? "Monitor" : "Work")").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
