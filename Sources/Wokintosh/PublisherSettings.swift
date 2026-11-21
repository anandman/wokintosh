import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins
import WokintoshCore

struct PublisherSettingsView:View {
    @ObservedObject var store:DashboardStore
    @ObservedObject var publisher:WidgetPublisher
    @State private var address=""
    @State private var error:String?
    @State private var showPairing=false
    var body:some View {
        Form {
            Section("Wokintosh on your iPhone or iPad") {
                Toggle("Publish selected widgets",isOn:Binding(get:{publisher.options.enabled},set:{value in change{$0.enabled=value}}))
                Text(publisher.status).foregroundStyle(publisher.options.enabled ? .primary : .secondary)
                Text("Your iPhone or iPad can read selected Agent widgets over your private Tailscale network. Keep Wokintosh and this Mac running; the dashboard window can be closed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if publisher.options.enabled {
                Section("Widgets to publish") {
                    ForEach(store.document.widgets.filter{$0.kind == .agents}) {widget in
                        Toggle(widgetSettingsName(widget,in:store.document.widgets),isOn:Binding(get:{publisher.options.selectedWidgetIDs.contains(widget.id)},set:{enabled in
                            change {if enabled {$0.selectedWidgetIDs.insert(widget.id)} else {$0.selectedWidgetIDs.remove(widget.id)}}
                        }))
                    }
                    Text("Filters and ordering follow each Mac widget. Other widget types can be added in future versions. Publishing choices and device access keys stay on this Mac when exporting a setup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Private connection") {
                    Text("Run this once in Terminal on this Mac to connect the publisher to Tailscale. It adds only Wokintosh’s private route.")
                    HStack {
                        Text(WidgetPublisher.setupCommand).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                        Button("Copy") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(WidgetPublisher.setupCommand,forType:.string)}
                    }
                    TextField("HTTPS address shown by Tailscale",text:$address).textFieldStyle(.roundedBorder)
                    Button("Save address") {
                        guard let endpoint=WidgetPublisher.endpoint(from:address) else {error="Use the HTTPS address ending in .ts.net shown by Tailscale.";return}
                        change{$0.endpoint=endpoint};address=endpoint
                    }
                    Text("The connection uses private HTTPS port 9443. It does not use Tailscale Funnel or change your other services.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Pair your iPhone or iPad") {
                    Button(showPairing ? "Hide pairing code" : "Show pairing code") {showPairing.toggle()}
                        .disabled(publisher.options.endpoint.isEmpty || store.document.previewMode)
                    if showPairing,let pairing=try? publisher.pairing(),let data=try? pairing.encoded(),let image=qr(data) {
                        Image(nsImage:image).interpolation(.none).resizable().frame(width:230,height:230)
                            .padding(12).background(.white).accessibilityLabel("Private Wokintosh device pairing code")
                        Text("Scan this in Wokintosh on your iPhone or iPad. This code grants read access to your published widgets; keep it private.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Change access key") {perform {try publisher.rotateCredential();showPairing=false;store.publishWidgets()}}
                    Text("Changing the key requires pairing your device again. Stopping publishing prevents new access; your device may retain its last snapshot until it refreshes or you unpair it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {Text(error).foregroundStyle(.red)}
        }.formStyle(.grouped)
            .onAppear {address=publisher.options.endpoint}
            .onChange(of:publisher.options.enabled) {_,enabled in if !enabled {showPairing=false}}
    }
    private func change(_ edit:(inout PublisherOptions)->Void) {
        perform {var next=publisher.options;edit(&next);try publisher.setOptions(next,widgets:store.document.widgets);store.publishWidgets()}
    }
    private func perform(_ body:()throws->Void) {do {try body();error=nil} catch {self.error=error.localizedDescription}}
    private func qr(_ data:Data)->NSImage? {
        let filter=CIFilter.qrCodeGenerator();filter.message=data;filter.correctionLevel="M"
        guard let output=filter.outputImage?.transformed(by:CGAffineTransform(scaleX:5,y:5)),
              let image=CIContext().createCGImage(output,from:output.extent) else {return nil}
        return NSImage(cgImage:image,size:NSSize(width:230,height:230))
    }
}
