import SwiftUI
import WokintoshCore

struct PhoneSessionSheet:View {
    @ObservedObject var store:PhoneStore
    let row:PublishedAgentRow
    var body:some View {
        if store.sessionPanel == .backgroundTasks {PhoneBackgroundTaskSheet(store:store,rowID:row.id)}
        else {PhoneSessionDetail(store:store,row:row)}
    }
}
struct PhoneBackgroundTaskSheet:View {
    @ObservedObject var store:PhoneStore
    let rowID:String
    private var row:PublishedAgentRow? {store.selectedSession?.id==rowID ? store.selectedSession : nil}
    var body:some View {
        PhoneModal(title:"Background Tasks") {
            PhoneRetroWindow(title:row?.session.title ?? "Session") {
                VStack(alignment:.leading,spacing:16) {
                    if let row {
                        Text(row.hostName+" · "+row.session.statusLabel).font(PhonePalette.font(15)).foregroundStyle(PhonePalette.secondary)
                        ForEach(row.session.background?.tasks ?? []) {task in taskView(task,row:row);Divider()}
                        if row.session.background?.tasks.isEmpty != false {
                            Text("No tracked background tasks. Update this machine’s collector if tasks are missing.").foregroundStyle(PhonePalette.secondary)
                        }
                        if row.backgroundControls == nil {Text("Role changes need Allow Agent controls enabled on your publishing Mac and a connected source.").font(.caption).foregroundStyle(PhonePalette.secondary)}
                    } else {Text("This session is no longer available.")}
                    Text("Work keeps a session Working. Monitor allows Monitoring between active turns. Automatic uses the provider’s task type. Choices apply to this task run; they don’t start or stop it.")
                        .font(PhonePalette.font(14)).foregroundStyle(PhonePalette.secondary).fixedSize(horizontal:false,vertical:true)
                    if let error=store.message {Text(error).font(.callout).foregroundStyle(PhonePalette.attention)}
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.task {await store.refresh()}
    }
    private func taskView(_ task:WokintoshCore.BackgroundTask,row:PublishedAgentRow)->some View {
        VStack(alignment:.leading,spacing:8) {
            Text(task.label).font(PhonePalette.font(18,bold:true)).fixedSize(horizontal:false,vertical:true)
            Text(task.kind.capitalized+" · "+(task.status.isActive && !task.isVerified(at:Date()) ? "Unverified" : task.status.label))
                .font(PhonePalette.font(14)).foregroundStyle(PhonePalette.secondary)
            Text(task.id).font(.caption.monospaced()).foregroundStyle(PhonePalette.secondary).lineLimit(2).textSelection(.enabled)
            if task.status.isActive {
                Picker("Treat as",selection:Binding(get:{task.role ?? .automatic},set:{role in
                    guard let command=store.backgroundRoleCommand(role,task:task,row:row) else {return}
                    Task {await store.perform(command)}
                })) {
                    ForEach(BackgroundTaskRole.allCases) {role in Text(role.title).tag(role)}
                }.pickerStyle(.segmented).frame(minHeight:44)
                    .disabled(store.preview || store.performingAction || store.backgroundRoleCommand(.automatic,task:task,row:row)==nil)
                    .accessibilityLabel("Role for \(task.label)")
                Text("Automatic: \(task.kind == "monitor" ? "Monitor" : "Work")").font(.caption).foregroundStyle(PhonePalette.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
