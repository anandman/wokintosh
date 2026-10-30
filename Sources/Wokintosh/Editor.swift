import AppKit
import SwiftUI
import WokintoshCore

struct EditorView: View {
    @ObservedObject var store:DashboardStore
    @State private var showSources=false
    @State private var actualSize=false
    @State private var calibration=1.0
    var body:some View {
        HStack(spacing:0) {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    Text("Wokintosh").font(.title.bold())
                    Text("Widget Library").font(.headline)
                    LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:8) {
                        ForEach(WidgetKind.allCases) { kind in
                            Button { store.add(kind) } label: { VStack(spacing:6) { Image(systemName:symbol(kind)).font(.title2);Text(kind.title).font(.caption) }.frame(maxWidth:.infinity,minHeight:66) }
                            .buttonStyle(.bordered).accessibilityLabel("Add \(kind.title) widget")
                        }
                    }
                    Divider()
                    Text("On This Dashboard").font(.headline)
                    ForEach(store.document.widgets) { widget in
                        Button { store.selectedID=widget.id } label: {
                            HStack {Image(systemName:symbol(widget.kind));Text(widget.kind.title);Spacer();if store.selectedID==widget.id {Image(systemName:"checkmark")}}
                                .padding(7).background(store.selectedID==widget.id ? Color.accentColor.opacity(0.15) : .clear).clipShape(RoundedRectangle(cornerRadius:5))
                        }.buttonStyle(.plain)
                    }
                    if let widget=store.selectedWidget { inspector(widget) }
                    Divider()
                    Text("Appearance").font(.headline)
                    HStack {Text("Text size");Spacer();Text("\(Int(store.document.textScale*100))%").monospacedDigit()}
                    Slider(value:$store.document.textScale,in:1...1.6,step:0.05).accessibilityLabel("Dashboard text size")
                    Toggle("Sample data",isOn:$store.document.previewMode)
                    Text("Sample data is labeled PREVIEW on the dashboard.").font(.caption).foregroundStyle(.secondary)
                    Button("Machines & Live Sources…") { showSources=true }.buttonStyle(.bordered)
                    Divider()
                    Text("Presentation").font(.headline)
                    Picker("Display",selection:Binding<UInt32>(get:{store.document.displayID ?? screenID(NSScreen.main)},set:{store.document.displayID=$0})) {
                        ForEach(Array(NSScreen.screens.enumerated()),id:\.offset) { index, screen in
                            Text("\(index+1). \(screen.localizedName)").tag(screenID(screen))
                        }
                    }.labelsHidden()
                    Button("Present on Display") { store.presentDashboard?(store.document.displayID) }.buttonStyle(.borderedProminent)
                    Text("Escape returns the dashboard to a window. Command-comma opens this editor.").font(.caption).foregroundStyle(.secondary)
                    Button("Restore Default Layout") { store.resetLayout() }.buttonStyle(.bordered)
                }.padding(16)
            }.frame(width:290).background(Color(nsColor:.controlBackgroundColor))
            Divider()
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text("Layout Editor").font(.title2.bold())
                    Spacer()
                    Toggle("Actual-size preview",isOn:$actualSize).toggleStyle(.switch).fixedSize()
                    Button { Task { await store.refresh() } } label:{Label("Refresh",systemImage:"arrow.clockwise")}.disabled(store.refreshing)
                }
                Text("Move a widget by its title bar. Drag its purple corner to resize. Content reflows inside the space you choose.").foregroundStyle(.secondary)
                GeometryReader { geometry in
                    let fit=min(geometry.size.width,geometry.size.height*16/9)
                    let width=actualSize ? min(fit,store.document.previewWidthMM*pointsPerMM*calibration) : fit
                    DashboardCanvas(store:store,editing:true).frame(width:width,height:width*9/16).position(x:geometry.size.width/2,y:geometry.size.height/2)
                }.background(Color(nsColor:.underPageBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:8))
                if actualSize {
                    HStack {Text("Target width: 111 mm");Slider(value:$calibration,in:0.6...1.6).frame(width:200);Text("Match the preview width to a ruler, then judge it from your usual viewing distance.").font(.caption).foregroundStyle(.secondary)}
                }
                if let notice=store.notice { Text(notice).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    Text(store.document.previewMode ? "Preview • fictional sessions and readings" : "Live • local and connected machines").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("1280 × 720 • 5-inch target").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18)
        }.sheet(isPresented:$showSources) { SourcesSheet(store:store) }
    }
    @ViewBuilder func inspector(_ widget:DashboardWidget)->some View {
        Divider()
        Text("\(widget.kind.title) Settings").font(.headline)
        HStack {frameField("X",key:\.x,dimension:1280,widget:widget);frameField("Y",key:\.y,dimension:682,widget:widget)}
        HStack {frameField("Width",key:\.width,dimension:1280,widget:widget);frameField("Height",key:\.height,dimension:682,widget:widget)}
        if widget.kind == .agents || widget.kind == .system {
            Picker("Source",selection:Binding(get:{widget.hostID ?? ""},set:{value in store.change(widget.id){$0.hostID=value.isEmpty ? nil : value}})) {
                Text(widget.kind == .agents ? "All machines" : "This Mac").tag("")
                if store.document.previewMode {Text("Dev Mini (preview)").tag("dev");Text("Minion (preview)").tag("minion")}
                ForEach(store.hosts,id:\.id){host in Text(host.name).tag(host.id)}
            }
        }
        if widget.kind == .agents {
            Picker("Harness",selection:Binding(get:{widget.provider ?? ""},set:{value in store.change(widget.id){$0.provider=value.isEmpty ? nil : value}})) {Text("Codex + Claude Code").tag("");Text("Codex").tag("codex");Text("Claude Code").tag("claude")}
            Toggle("Include recent finished sessions",isOn:Binding(get:{widget.showFinished},set:{v in store.change(widget.id){$0.showFinished=v}}))
            Toggle("Include helper agents",isOn:Binding(get:{widget.showHelpers},set:{v in store.change(widget.id){$0.showHelpers=v}}))
            Text("Sessions needing you appear first. More height reveals more rows; more width allows a compact row layout.").font(.caption).foregroundStyle(.secondary)
        }
        HStack {Button("Duplicate"){store.duplicateSelected()};Button("Remove",role:.destructive){store.removeSelected()}}.buttonStyle(.bordered)
    }
    func frameField(_ label:String,key:WritableKeyPath<WidgetFrame,Double>,dimension:Double,widget:DashboardWidget)->some View {
        VStack(alignment:.leading,spacing:3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label,value:Binding(get:{widget.frame[keyPath:key]*dimension},set:{v in store.change(widget.id){$0.frame[keyPath:key]=v/dimension}}),format:.number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).accessibilityLabel("Widget \(label)")
        }
    }
    var pointsPerMM:Double {
        guard let screen=NSScreen.main else{return 72/25.4}
        let physical=CGDisplayScreenSize(screenID(screen)).width
        return physical>0 ? screen.frame.width/physical : 72/25.4
    }
    func screenID(_ screen:NSScreen?)->UInt32 {(screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0}
    func symbol(_ kind:WidgetKind)->String {switch kind{case .agents:return "person.2";case .music:return "music.note";case .system:return "cpu";case .clock:return "clock";case .weather:return "cloud.sun";case .calendar:return "calendar"}}
}

struct SourcesSheet:View {
    @ObservedObject var store:DashboardStore
    @Environment(\.dismiss) var dismiss
    @State private var machineName=""
    @State private var destination=""
    @State private var collectorPath="~/.local/bin/wokintosh-agent"
    @State private var query=""
    @State private var places:[PlaceResult]=[]
    @State private var sourceError:String?
    @State private var searching=false
    @State private var confirmHooks:String?
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Text("Machines & Live Sources").font(.title2.bold());Spacer();Button("Done"){dismiss()}.keyboardShortcut(.defaultAction)}
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    GroupBox("Agent Machines") {
                        VStack(alignment:.leading,spacing:10) {
                            Text("This Mac is collected automatically. Connect another Mac or Linux machine using an SSH alias or user@host with key-based access.").font(.callout)
                            ForEach(Array(store.feeds.keys.sorted()),id:\.self) { key in
                                if let feed=store.feeds[key] {HStack {Circle().fill(feed.connected ? .green : .orange).frame(width:8,height:8);Text(feed.name);Spacer();Text(feed.error ?? "Connected").font(.caption).foregroundStyle(.secondary).lineLimit(2)}}
                            }
                            ForEach(store.document.remoteHosts) {host in HStack {Text(host.name);Text(host.destination).foregroundStyle(.secondary);Spacer();Button("Remove"){store.document.remoteHosts.removeAll{$0.id==host.id}}}}
                            HStack {TextField("Machine name",text:$machineName);TextField("SSH alias or user@host",text:$destination)}
                            TextField("Remote collector path",text:$collectorPath)
                            HStack {Button("Add Machine"){addMachine()}.disabled(destination.isEmpty);Button("Export Collector…"){exportCollector()};Spacer()}
                            Text("Install the exported executable as ~/.local/bin/wokintosh-agent on each machine (Python 3.10+). SSH host keys and keys must be configured in Terminal first.").font(.caption).foregroundStyle(.secondary)
                            Divider()
                            Text("Precise local approval/input signals").font(.headline)
                            Text("Observational hooks improve attention status. Existing hooks are preserved and backed up. New sessions load the changes.").font(.caption).foregroundStyle(.secondary)
                            HStack {Button("Enable Codex Hooks…"){confirmHooks="codex"};Button("Enable Claude Code Hooks…"){confirmHooks="claude"}}
                        }.padding(7)
                    }
                    GroupBox("Apple Music & Calendar") {
                        VStack(alignment:.leading,spacing:8) {
                            HStack {Text(store.native.music.status);Spacer();Button("Connect Apple Music"){Task{await store.native.connectMusic()}}}
                            HStack {Text(store.native.calendar.status);Spacer();Button("Enable Calendar"){Task{await store.native.requestCalendarAccess()}}}
                            Text("Access is requested only when you connect a source. Media playback controls act on Apple Music.").font(.caption).foregroundStyle(.secondary)
                        }.padding(7)
                    }
                    GroupBox("Weather Location") {
                        VStack(alignment:.leading,spacing:8) {
                            if !store.document.weatherPlace.isEmpty {Text("Selected: \(store.document.weatherPlace)").font(.headline)}
                            HStack {TextField("City or place",text:$query).onSubmit{search()};Button(searching ? "Searching…" : "Search"){search()}.disabled(searching || query.trimmingCharacters(in:.whitespaces).isEmpty)}
                            ForEach(places) {place in Button(place.label){store.document.weatherPlace=place.label;store.document.latitude=place.latitude;store.document.longitude=place.longitude;places=[];Task{await store.native.refresh(document:store.document)}}.buttonStyle(.link)}
                            Toggle("Use Fahrenheit",isOn:$store.document.fahrenheit)
                            HStack {Link("Weather by Open-Meteo",destination:URL(string:"https://open-meteo.com/")!);Text("•");Link("Place names by GeoNames",destination:URL(string:"https://www.geonames.org/")!)}.font(.caption)
                        }.padding(7)
                    }
                    if let error=sourceError {Text(error).foregroundStyle(.orange).textSelection(.enabled)}
                    if let notice=store.notice {Text(notice).font(.caption).textSelection(.enabled)}
                }.textFieldStyle(.roundedBorder)
            }
        }.padding(22).frame(width:750,height:780)
        .confirmationDialog("Enable observational hooks?",isPresented:Binding(get:{confirmHooks != nil},set:{if !$0{confirmHooks=nil}}),titleVisibility:.visible) {
            Button("Enable Hooks") {if let provider=confirmHooks {Task{await store.installHooks(provider:provider)}};confirmHooks=nil}
            Button("Cancel",role:.cancel){confirmHooks=nil}
        } message: {Text("This adds local Wokintosh observers to the selected harness settings. They report status and never approve, deny or continue agent actions.")}
    }
    func addMachine() {
        guard RemoteCommand.arguments(destination:destination,collectorPath:collectorPath) != nil else {sourceError="Use an SSH alias or user@host and an absolute or ~/ collector path, without shell commands.";return}
        store.document.remoteHosts.append(RemoteHost(name:machineName.isEmpty ? destination : machineName,destination:destination,collectorPath:collectorPath))
        machineName="";destination="";sourceError=nil;Task{await store.refresh()}
    }
    func search() { searching=true;sourceError=nil;Task{do{places=try await store.native.searchPlaces(query:query);if places.isEmpty{sourceError="No places found."}}catch{sourceError=error.localizedDescription};searching=false} }
    func exportCollector() {
        guard let source=store.collectorURL else{sourceError="Bundled collector is missing.";return}
        let panel=NSSavePanel();panel.nameFieldStringValue="wokintosh-agent";panel.title="Export Mac / Linux Collector"
        if panel.runModal() == .OK,let url=panel.url {
            do {try Data(contentsOf:source).write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:url.path);sourceError="Collector exported. Install on your agent machine and connect it above."}catch{sourceError=error.localizedDescription}
        }
    }
}
