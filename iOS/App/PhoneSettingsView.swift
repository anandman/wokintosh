import SwiftUI
import WokintoshCore

struct PhoneSettingsView:View {
    @ObservedObject var store:PhoneStore
    @State private var confirmUnpair=false
    var body:some View {
        PhoneModal(title:"Settings") {
            VStack(spacing:15) {
                PhoneRetroWindow(title:"Connection") {
                    VStack(alignment:.leading,spacing:12) {
                        Label(store.snapshot.feed?.publisherName ?? "Your publishing Mac",systemImage:"desktopcomputer").font(PhonePalette.font(18,bold:true))
                        Text(connectionLabel).font(PhonePalette.font(15)).foregroundStyle(PhonePalette.secondary)
                        if let date=store.selectedWidget?.agents?.asOf {Text("As of \(date.formatted(date:.abbreviated,time:.shortened))").font(.caption)}
                        if let widgets=store.snapshot.feed?.widgets,widgets.count>1 {
                            Picker("Agent widget",selection:$store.selectedWidgetID) {ForEach(widgets){Text($0.name).tag(Optional($0.id))}}.tint(.black)
                        }
                        if store.snapshot.paired {
                            Button("Unpair this device",role:.destructive) {confirmUnpair=true}.frame(minHeight:44).tint(PhonePalette.attention)
                        } else {
                            Text("Show the pairing code in Wokintosh Settings → iPhone & iPad on your Mac.")
                            Button("Scan pairing code",systemImage:"qrcode.viewfinder") {store.settingsSheet = .scan}.buttonStyle(PhoneRetroButtonStyle(prominent:true))
                            Button("Paste pairing code") {store.settingsSheet = .paste}.buttonStyle(PhoneRetroButtonStyle())
                        }
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                }
                PhoneRetroWindow(title:"Home Screen") {
                    VStack(alignment:.leading,spacing:12) {
                        Text("Hold an empty part of your Home Screen, choose Edit → Add Widget, then search for Wokintosh.").font(PhonePalette.font(16))
                        Text("Choose Agents and a size. Hold the new widget, choose Edit Widget, and select your published Agent widget.").font(PhonePalette.font(16))
                        Text("Keep your publishing Mac and Tailscale running. iOS decides when widgets refresh; check their As of time.").font(PhonePalette.font(14,relativeTo:.caption)).foregroundStyle(PhonePalette.secondary)
                    }.padding(16)
                }
            }
        }
        .sheet(item:$store.settingsSheet,onDismiss:store.settingsSheetDismissed) {sheet in
            switch sheet {
            case .scan:PhoneScanSheet {store.settingsSheet=nil;store.pair($0)}
            case .paste:PhonePasteSheet {store.pair($0)}
            }
        }
        .confirmationDialog("Unpair this device and clear its saved widget data?",isPresented:$confirmUnpair,titleVisibility:.visible) {Button("Unpair",role:.destructive) {store.unpair()}}
        .alert("Wokintosh",isPresented:Binding(get:{store.message != nil},set:{if !$0 {store.message=nil}})) {Button("OK") {store.message=nil}} message:{Text(store.message ?? "")}
    }
    private var connectionLabel:String {
        if !store.snapshot.paired {return "Not paired"}
        if store.snapshot.state == .offline {return "Offline · saved snapshot"}
        if store.selectedWidget?.agents?.offlineSourceCount ?? 0 > 0 {return "A source is offline · last known state"}
        return "Connected over your private Tailscale network"
    }
}
