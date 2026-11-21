import SwiftUI
import UIKit
import WidgetKit
import WokintoshCore

@main struct WokintoshPhoneApp:App {
    @StateObject private var store=PhoneStore()
    @Environment(\.scenePhase) private var scenePhase
    var body:some Scene {
        WindowGroup {
            PhoneRootView(store:store)
                .onOpenURL {store.handle($0)}
                .task {await store.refresh()}
                .onChange(of:scenePhase) {_,phase in if phase == .active {Task {await store.refresh()}}}
        }
    }
}

struct PhoneRootView:View {
    @ObservedObject var store:PhoneStore
    @State private var scanner=false
    @State private var pasteCode=false
    @State private var pairingText=""
    @State private var confirmUnpair=false
    var body:some View {
        NavigationStack {
            List {
                if store.preview {Text("SAMPLE DATA").font(.caption.bold()).foregroundStyle(.purple)}
                if !store.snapshot.paired {
                    Section {
                        Label(store.snapshot.state == .authorizationRequired ? "Pair with your Mac again" : "Your agents, at a glance",systemImage:"desktopcomputer.and.iphone")
                            .font(.title3.bold()).padding(.vertical,8)
                        Text("On your Mac, open Wokintosh Settings → iPhone & iPad, choose the Agent widgets to publish, then show the pairing code.")
                        Button("Scan pairing code",systemImage:"qrcode.viewfinder") {scanner=true}
                        Button("Paste pairing code") {pasteCode=true}
                    }
                } else {
                    Section {
                        HStack {
                            Label(connectionLabel,systemImage:store.snapshot.state == .offline ? "wifi.slash" : "checkmark.shield")
                            Spacer()
                            if store.refreshing {ProgressView()}
                            else {Button("Refresh",systemImage:"arrow.clockwise") {Task {await store.refresh()}}.labelStyle(.iconOnly)}
                        }.font(.subheadline)
                        if let date=store.selectedWidget?.agents?.asOf {Text("As of \(date.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary)}
                        if let widgets=store.snapshot.feed?.widgets,widgets.count>1 {
                            Picker("Agent widget",selection:$store.selectedWidgetID) {
                                ForEach(widgets) {widget in Text(widget.name).tag(Optional(widget.id))}
                            }
                        }
                    }
                    if let widget=store.selectedWidget,let agents=widget.agents,let publisherID=store.snapshot.feed?.publisherID {
                        Section(widget.name) {
                            ForEach(agents.rows) {row in
                                let route=PhoneRoute(publisherID:publisherID,widgetID:widget.id,rowID:row.id)
                                Button {store.open(route)} label: {
                                    PhoneAgentRowView(row:row,offline:store.snapshot.state == .offline,at:Date())
                                }.buttonStyle(.plain)
                            }
                            if agents.rows.isEmpty && agents.totalCount==0 {Text("No active sessions").foregroundStyle(.secondary)}
                            if agents.hiddenCount>0 {Text("\(agents.hiddenCount) more sessions on your Mac").font(.caption).foregroundStyle(.secondary)}
                            if agents.earlierDoneCount>0 {Text("Earlier Done · \(agents.earlierDoneCount) unread").font(.caption).foregroundStyle(.purple)}
                        }
                    } else {
                        Text("No compatible Agent widgets are published. Select one in Settings → iPhone & iPad on your Mac.").foregroundStyle(.secondary)
                    }
                    Section {
                        Text("Add a Wokintosh widget to your Home Screen, then choose a published Agent widget. iOS controls refresh timing; it may take longer than 15 minutes.").font(.caption).foregroundStyle(.secondary)
                        Button("Unpair this device",role:.destructive) {confirmUnpair=true}
                    }
                }
            }
            .navigationTitle("Wokintosh")
            .refreshable {await store.refresh()}
            .sheet(isPresented:$scanner) {PhoneScannerView {text in scanner=false;store.pair(text)}}
            .sheet(isPresented:$pasteCode) {
                NavigationStack {
                    Form {
                        Text("Paste only the private pairing code from Wokintosh on your Mac.")
                        TextEditor(text:$pairingText).font(.system(.caption,design:.monospaced)).frame(minHeight:140)
                        Button("Pair") {let code=pairingText;pairingText="";pasteCode=false;store.pair(code)}.disabled(pairingText.isEmpty)
                    }.navigationTitle("Pair with your Mac").toolbar {Button("Cancel") {pairingText="";pasteCode=false}}
                }
            }
            .sheet(item:$store.selectedSession) {_ in if let row=store.selectedSession {sessionDetail(row)}}
            .alert("Wokintosh",isPresented:Binding(get:{store.message != nil},set:{if !$0 {store.message=nil}})) {Button("OK") {store.message=nil}} message: {Text(store.message ?? "")}
            .confirmationDialog("Unpair this device and clear its saved widget data?",isPresented:$confirmUnpair,titleVisibility:.visible) {
                Button("Unpair",role:.destructive) {store.unpair()}
            }
        }
    }
    private var connectionLabel:String {
        if store.snapshot.state == .offline {return "Offline · saved snapshot"}
        if (store.selectedWidget?.agents?.offlineSourceCount ?? 0)>0 {return "Source offline · last known state"}
        return store.snapshot.feed?.publisherName ?? "Publishing Mac"
    }
    private func sessionDetail(_ row:PublishedAgentRow)->some View {
        NavigationStack {
            Form {
                PhoneAgentRowView(row:row,offline:store.snapshot.state == .offline,at:Date())
                if let date=row.sourceObservedAt {LabeledContent("As of",value:date.formatted(date:.abbreviated,time:.shortened))}
                if let url=row.session.openURLs?.iOS?.url {
                    Button("Open session") {store.openSelectedSession()}
                    if row.session.openURLs?.iOS?.fallbackURL != nil {
                        Button(row.session.openURLs?.iOS?.fallbackLabel ?? "Open backup link") {store.openSelectedSession(backup:true)}
                    }
                    if let note=store.navigationMessage {Text(note).foregroundStyle(.orange)}
                    Text("Session actions happen in the official app. Opening a session does not review its Done notice.").font(.caption).foregroundStyle(.secondary)
                    Text(url.scheme=="claude" ? "Opens Claude." : "Opens the session’s app.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No direct link is available. Update the collector on this session’s machine; Claude sessions also need connected Remote Control and an observed bridge ID.").foregroundStyle(.secondary)
                }
            }.navigationTitle("Session").navigationBarTitleDisplayMode(.inline)
                .toolbar {Button("Done") {store.selectedSession=nil}}
        }
    }
}
