import SwiftUI
import WokintoshCore

struct PhoneModal<Content:View>:View {
    let title:String
    @ViewBuilder let content:()->Content
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Text(title).font(PhonePalette.font(20,bold:true,relativeTo:.headline))
                Spacer()
                Button("Done") {dismiss()}.buttonStyle(PhoneRetroButtonStyle())
            }.padding(12).background(PhonePalette.chrome)
            ScrollView {content().frame(maxWidth:900).padding(14).frame(maxWidth:.infinity)}
        }.foregroundStyle(.black).background(PhonePalette.desktop.ignoresSafeArea()).preferredColorScheme(.light)
    }
}
struct PhonePasteSheet:View {
    let onCode:(String)->Void
    @State private var text=""
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        PhoneModal(title:"Pair with your Mac") {
            PhoneRetroWindow(title:"Pairing code") {
                VStack(alignment:.leading,spacing:14) {
                    Text("Paste the private pairing code shown by Wokintosh on your Mac.").font(PhonePalette.font())
                    TextEditor(text:$text).font(.system(.caption,design:.monospaced)).frame(minHeight:180)
                        .scrollContentBackground(.hidden).padding(6).background(.white).overlay(Rectangle().stroke(.black,lineWidth:1))
                        .accessibilityLabel("Private pairing code").privacySensitive()
                    Button {let code=text;text="";onCode(code);dismiss()} label: {Text("Pair").frame(maxWidth:.infinity)}
                        .buttonStyle(PhoneRetroButtonStyle(prominent:true)).disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }.padding(16)
            }
        }.onDisappear {text=""}
    }
}
struct PhoneScanSheet:View {
    let onCode:(String)->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Text("Scan pairing code").font(PhonePalette.font(20,bold:true,relativeTo:.headline))
                Spacer()
                Button("Cancel") {dismiss()}.buttonStyle(PhoneRetroButtonStyle())
            }.padding(12).background(PhonePalette.chrome)
            PhoneScannerView(onCode:onCode).padding(12)
        }.background(PhonePalette.desktop.ignoresSafeArea()).foregroundStyle(.black).preferredColorScheme(.light)
    }
}
struct PhoneSessionDetail:View {
    @ObservedObject var store:PhoneStore
    let row:PublishedAgentRow
    var body:some View {
        PhoneModal(title:"Session") {
            PhoneRetroWindow(title:"Session details") {
                VStack(alignment:.leading,spacing:16) {
                    PhoneSessionInformation(row:row,offline:store.snapshot.state == .offline)
                    if let date=row.sourceObservedAt {Text("As of \(date.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(PhonePalette.secondary)}
                    if row.session.openURLs?.iOS?.url != nil {
                        Button("Open session") {store.openSelectedSession()}.buttonStyle(PhoneRetroButtonStyle(prominent:true))
                        if let target=row.session.openURLs?.iOS,target.fallbackURL != nil {
                            Button(target.fallbackLabel ?? "Open backup link") {store.openSelectedSession(backup:true)}.buttonStyle(PhoneRetroButtonStyle())
                        }
                        if let note=store.navigationMessage {Text(note).foregroundStyle(PhonePalette.attention)}
                        Text("Opening a session does not review its Done notice.").font(.caption).foregroundStyle(PhonePalette.secondary)
                    } else {
                        Text("No mobile link is available yet. Update Wokintosh’s collector on \(row.hostName); Claude sessions also need Remote Control connected.").foregroundStyle(PhonePalette.secondary)
                    }
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
            }
        }
    }
}
struct PhoneEarlierDoneView:View {
    @ObservedObject var store:PhoneStore
    let selection:PhoneWidgetRoute
    private var agents:PublishedAgents? {
        guard store.snapshot.feed?.publisherID==selection.publisherID else {return nil}
        return store.snapshot.feed?.widgets.first(where:{$0.id==selection.widgetID})?.agents
    }
    var body:some View {
        PhoneModal(title:"Earlier Done") {
            PhoneRetroWindow(title:"Unread completions") {
                VStack(alignment:.leading,spacing:0) {
                    if let agents {
                        Text("Earlier Done stays unread until you review it.").font(PhonePalette.font(15)).padding(12)
                        if let bulk=store.controlCommand(.reviewEarlierDone) {
                            Button {Task {await store.perform(bulk)}} label: {Label("Review shown Earlier Done",systemImage:"checkmark.circle")}
                                .buttonStyle(PhoneRetroButtonStyle()).disabled(store.performingAction).padding(12)
                        }
                        ForEach(agents.earlierRows ?? []) {row in
                            Rectangle().fill(.black.opacity(0.25)).frame(height:1)
                            PhoneSessionRow(store:store,row:row)
                        }
                        if (agents.earlierRows ?? []).isEmpty {Text(agents.earlierDoneCount>0 ? "More completions are available on your Mac." : "All caught up.").padding(16)}
                        let hidden=max(0,agents.earlierDoneCount-(agents.earlierRows?.count ?? 0))
                        if hidden>0 {Text("\(hidden) more Earlier Done notices on your Mac").font(.caption).padding(12)}
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        }
        .sheet(item:$store.selectedSession,onDismiss:store.sessionDetailsDismissed) {row in PhoneSessionDetail(store:store,row:row)}
        .alert("Wokintosh",isPresented:Binding(get:{store.message != nil},set:{if !$0 {store.message=nil}})) {Button("OK") {store.message=nil}} message:{Text(store.message ?? "")}
    }
}
