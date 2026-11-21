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
    @State private var showSettings=false
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:9) {
                PhoneRainbowMark().frame(width:24,height:25)
                Text("Wokintosh").font(PhonePalette.font(22,bold:true,relativeTo:.title2))
                Spacer(minLength:4)
                if store.refreshing || store.performingAction {ProgressView().tint(.black).padding(10)}
                Button {Task {await store.refresh()}} label: {Image(systemName:"arrow.clockwise").font(.system(size:19)).frame(width:44,height:44)}
                    .buttonStyle(.plain).accessibilityLabel("Refresh").disabled(store.refreshing || store.performingAction)
                Button {showSettings=true} label: {Image("PhoneMac").resizable().interpolation(.none).scaledToFit().frame(width:22,height:22).frame(width:44,height:44)}
                    .buttonStyle(.plain).accessibilityLabel("Settings")
            }.padding(.horizontal,14).padding(.vertical,3).foregroundStyle(.black)
                .background(PhonePalette.chrome.ignoresSafeArea(edges:.top))
                .overlay(alignment:.bottom) {Rectangle().fill(.black).frame(height:1.5)}
            ScrollView {
                VStack(spacing:15) {
                    if store.preview {Text("SAMPLE DATA").font(.caption.bold()).padding(5).background(PhonePalette.paper).foregroundStyle(.black)}
                    if store.snapshot.paired {pairedContent} else {pairingContent}
                }.frame(maxWidth:940).padding(14).frame(maxWidth:.infinity)
            }.refreshable {await store.refresh()}
        }.background(PhonePalette.desktop.ignoresSafeArea()).preferredColorScheme(.light)
            .sheet(isPresented:$showSettings) {PhoneSettingsView(store:store)}
            .sheet(isPresented:$scanner) {PhoneScanSheet {text in scanner=false;store.pair(text)}}
            .sheet(isPresented:$pasteCode) {PhonePasteSheet {store.pair($0)}}
            .sheet(item:Binding(get:{store.earlierSelection==nil ? store.selectedSession : nil},set:{store.selectedSession=$0})) {row in PhoneSessionDetail(store:store,row:row)}
            .sheet(item:$store.earlierSelection) {selection in PhoneEarlierDoneView(store:store,selection:selection)}
            .alert("Wokintosh",isPresented:Binding(get:{!showSettings && store.earlierSelection==nil && store.message != nil},set:{if !$0 {store.message=nil}})) {Button("OK") {store.message=nil}} message: {Text(store.message ?? "")}

    }
    private var pairingContent:some View {
        PhoneRetroWindow(title:"Welcome") {
            VStack(alignment:.leading,spacing:18) {
                HStack(alignment:.top,spacing:14) {
                    Image("PhoneMac").resizable().interpolation(.none).scaledToFit().frame(width:48,height:48).accessibilityHidden(true)
                    VStack(alignment:.leading,spacing:5) {
                        Text(store.snapshot.state == .authorizationRequired ? "Pair with your Mac again" : "Your agents, at a glance.").font(PhonePalette.font(24,bold:true,relativeTo:.title2))
                        Text("Claude Code and Codex, across your machines.").foregroundStyle(PhonePalette.secondary)
                    }
                }
                Text("On your Mac, open Wokintosh Settings → iPhone & iPad. Choose your Agent widgets, then show the pairing code.")
                Button {scanner=true} label: {Label("Scan pairing code",systemImage:"qrcode.viewfinder").frame(maxWidth:.infinity)}.buttonStyle(PhoneRetroButtonStyle(prominent:true))
                Button {pasteCode=true} label: {Text("Paste pairing code").frame(maxWidth:.infinity)}.buttonStyle(PhoneRetroButtonStyle())
                Text("Keep Tailscale connected on both devices.").font(PhonePalette.font(14,relativeTo:.caption)).foregroundStyle(PhonePalette.secondary)
            }.font(PhonePalette.font()).padding(18)
        }
    }
    @ViewBuilder private var pairedContent:some View {
        if let widget=store.selectedWidget,let agents=widget.agents {
            PhoneRetroWindow(title:widget.name) {
                VStack(alignment:.leading,spacing:0) {
                    HStack(alignment:.top,spacing:6) {
                        VStack(alignment:.leading,spacing:3) {
                            Text("\(agents.attentionCount) need you · \(agents.doneCount) done · \(agents.workingCount) working").font(PhonePalette.font(17,bold:true))
                            HStack(spacing:5) {
                                if store.snapshot.state == .offline || agents.offlineSourceCount ?? 0 > 0 {Image(systemName:"wifi.slash");Text("Offline ·")}
                                if let date=agents.asOf {
                                    if Date().timeIntervalSince(date)>1800 || date.timeIntervalSinceNow>60 {Text("Stale ·")}
                                    Text("As of \(date.formatted(date:Calendar.current.isDateInToday(date) ? .omitted : .abbreviated,time:.shortened))")
                                }
                                else {Text("Not yet updated")}
                            }.font(PhonePalette.font(13,relativeTo:.caption)).foregroundStyle(PhonePalette.secondary)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                        if let bulk=store.controlCommand(.reviewAllDone) {
                            Button {Task {await store.perform(bulk)}} label: {Image(systemName:"checkmark.circle").font(.system(size:23)).frame(width:44,height:44)}
                                .buttonStyle(.plain).foregroundStyle(PhonePalette.purple).disabled(store.performingAction).accessibilityLabel(bulkLabel(agents))
                        }
                    }.padding(11)
                    if let note=store.snapshot.actionMessage {Text(note).font(.caption).foregroundStyle(PhonePalette.attention).padding(.horizontal,11).padding(.bottom,8)}
                    LazyVStack(spacing:0) {
                        ForEach(agents.rows) {row in
                            Rectangle().fill(.black.opacity(0.25)).frame(height:1)
                            PhoneSessionRow(store:store,row:row)
                        }
                    }
                    if agents.rows.isEmpty {Text(agents.totalCount==0 ? "No active sessions" : "Open your Mac to see more sessions.").foregroundStyle(PhonePalette.secondary).padding(18)}
                    if agents.hiddenCount>0 {Text("\(agents.hiddenCount) more sessions on your Mac").font(.caption).padding(10)}
                    if agents.earlierDoneCount>0 {
                        Button {store.showEarlierDone()} label: {Label("Earlier Done · \(agents.earlierDoneCount) unread",systemImage:"tray")}
                            .buttonStyle(PhoneRetroButtonStyle()).padding(11)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        } else {
            PhoneRetroWindow(title:"Agents") {Text("Choose an Agent widget to publish in Settings → iPhone & iPad on your Mac.").padding(18)}
        }
    }
    private func bulkLabel(_ agents:PublishedAgents)->String {
        agents.doneCount>(agents.rows+(agents.earlierRows ?? [])).filter(\.completionPending).count ? "Review shown Done" : "Review all Done"
    }
}
