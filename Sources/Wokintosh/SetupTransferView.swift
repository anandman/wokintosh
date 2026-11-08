import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WokintoshCore

struct SetupImportSelection:Identifiable {
    let id=UUID()
    let setup:DashboardSetup
}

@MainActor extension DashboardStore {
    func exportSetup(_ kind:SetupExportKind) {
        let panel=NSSavePanel()
        panel.title=kind == .template ? "Export Shareable Template" : "Export Setup"
        panel.nameFieldStringValue=kind == .template ? "Wokintosh-Template.json" : "Wokintosh-Setup.json"
        panel.allowedContentTypes=[.json]
        panel.message=kind == .template
            ? "Share a starting layout. Recipients choose their machines, weather locations, calendars, and actions."
            : "For your own Macs: includes machine names, SSH destinations, locations, filters, and configured links."
        guard panel.runModal() == .OK,let url=panel.url else {return}
        do {
            let references=feeds.compactMap { key,feed -> SetupMachineReference? in
                guard let host=feed.snapshot?.host else {return nil}
                return SetupMachineReference(id:host.id,name:feed.displayName,isLocal:key == "local",remoteHostID:key == "local" ? nil : UUID(uuidString:key))
            }
            // A collector reachable both locally and over SSH still has only one identity.
            let identities=Dictionary(grouping:references,by: \.id).values.compactMap { $0.first(where: \.isLocal) ?? $0.first }
            let setup=DashboardSetup.export(document:document,kind:kind,machines:identities)
            try setup.encoded().write(to:url,options:.atomic)
        } catch {presentMessage?(AppMessage(title:"Could Not Export Setup",message:error.localizedDescription,isError:true))}
    }

    func chooseSetupImport()->SetupImportSelection? {
        let panel=NSOpenPanel();panel.title="Import Wokintosh Setup";panel.allowedContentTypes=[.json]
        panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else {return nil}
        do {
            let handle=try FileHandle(forReadingFrom:url);defer {try? handle.close()}
            let data=try handle.read(upToCount:DashboardSetup.maximumBytes+1) ?? Data()
            return SetupImportSelection(setup:try DashboardSetup.decode(data))
        } catch {presentMessage?(AppMessage(title:"Could Not Read Setup",message:error.localizedDescription,isError:true));return nil}
    }
}

struct SetupImportView:View {
    @ObservedObject var store:DashboardStore
    let setup:DashboardSetup
    @State private var mapping:[String:String]
    @State private var errorText:String?
    @State private var importedBackup:URL?
    @Environment(\.dismiss) private var dismiss

    init(store:DashboardStore,setup:DashboardSetup) {
        self.store=store;self.setup=setup
        _mapping=State(initialValue:setup.defaultMachineMapping(localHostID:store.feeds["local"]?.snapshot?.host.id))
    }
    private var references:[SetupMachineReference] {
        Set(setup.widgets.compactMap(\.hostID)).sorted().map { id in
            setup.machines.first(where:{$0.id == id}) ?? SetupMachineReference(id:id,name:"Unavailable machine")
        }
    }
    private var additions:[RemoteHost] {
        setup.remoteHosts.filter { incoming in
            !store.document.remoteHosts.contains { $0.destination == incoming.destination && $0.collectorPath == incoming.collectorPath }
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(importedBackup == nil ? "Import \(setup.kind == .template ? "Template" : "Setup")" : "Setup Imported").font(.title2.bold())
            if let backup=importedBackup {
                Text("Your dashboard is saved. The previous setup was backed up here:")
                Text(backup.path).font(.callout.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Show Backup in Finder") {NSWorkspace.shared.activateFileViewerSelecting([backup])}
                    Spacer()
                    Button("Done") {dismiss()}.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Replace the current dashboard with \(setup.widgets.count) widgets. A backup is saved before importing.")
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        Text("Widgets: "+setup.widgets.map(\.kind.title).joined(separator:", ")).font(.callout)
                        Text("Imports widget settings, text size, and grid preference. This Mac’s display settings and unread Done/Blocked notices are kept.")
                            .font(.callout).foregroundStyle(.secondary)
                        if !references.isEmpty {
                            GroupBox("Widget machines") {
                                VStack(alignment:.leading,spacing:12) {
                                    ForEach(references) { reference in
                                        VStack(alignment:.leading,spacing:3) {
                                            Picker(reference.name+(reference.isLocal ? " (exporting Mac)" : ""),selection:Binding(
                                                get:{mapping[reference.id] ?? reference.id},
                                                set:{mapping[reference.id]=$0})) {
                                                Text("Keep source selection").tag(reference.id)
                                                ForEach(store.hosts.filter{$0.id != reference.id},id:\.id) {host in
                                                    Text(host.name).tag(host.id)
                                                }
                                            }
                                            if !store.hosts.contains(where:{$0.id == (mapping[reference.id] ?? reference.id)}) {
                                                Text("Currently unavailable; reconnect or choose another machine. This stays an explicit machine selection.")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }.padding(6)
                            }
                        }
                        if !additions.isEmpty {
                            GroupBox("Connections to add") {
                                VStack(alignment:.leading,spacing:8) {
                                    ForEach(additions) {host in
                                        Text("\(host.name) · \(host.destination)\(host.enabled ? "" : " · disabled")")
                                    }
                                    Text("Import starts normal read-only SSH polling for enabled connections. Manage collectors and hooks in Machines.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
                            }
                        }
                        Text(setup.kind == .template
                             ? "Choose machines, weather locations, calendars, and click actions after importing this template."
                             : "Check calendar and drive selections after import. Connect Music and Calendar on this Mac in Connections if needed.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:.infinity)
                if let errorText {Text(errorText).foregroundStyle(.red).textSelection(.enabled)}
                HStack {
                    Button("Cancel") {dismiss()}.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Import") {
                        do {importedBackup=try store.applySetup(setup,machineMapping:mapping);errorText=nil}
                        catch {errorText=error.localizedDescription}
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width:620).frame(minHeight:260,idealHeight:520,maxHeight:620)
    }
}
