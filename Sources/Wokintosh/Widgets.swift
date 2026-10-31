import SwiftUI
import WokintoshCore

struct WidgetContent: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget
    var body: some View {
        Group {
            switch widget.kind {
            case .agents: AgentWidget(store:store,widget:widget)
            case .music: MusicWidget(store:store)
            case .system: SystemWidget(store:store,widget:widget)
            case .clock: ClockWidget(textScale:store.document.textScale)
            case .weather: WeatherWidget(store:store,widget:widget)
            case .calendar: CalendarWidget(store:store,widget:widget)
            }
        }.clipped()
    }
}

struct AgentWidget: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget
    var body: some View {
        GeometryReader { geometry in
            let t=store.document.textScale
            let wide=geometry.size.width > 900
            let narrow=geometry.size.width < 440
            let rowHeight=(wide ? 43.0 : (narrow ? 69.0 : 61.0))*t
            let header=(narrow ? 39.0 : 45.0)*t
            let capacity=max(0,Int((geometry.size.height-header-30)/rowHeight))
            let page=AgentPresentation.make(rows:store.rows(for:widget),capacity:capacity,showFinished:widget.showFinished)
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:8) {
                    Text("\(page.attentionCount) need you · \(page.doneCount) done · \(page.workingCount) working")
                        .font(retroFont((narrow ? 20 : 27)*t)).lineLimit(1)
                    Spacer(minLength:0)
                    if page.doneCount>0 {
                        Button { store.reviewAllCompletions(for:widget) } label: { Label("Review Done",systemImage:"checkmark.circle") }
                            .labelStyle(.iconOnly).font(.system(size:24*t)).buttonStyle(.plain).foregroundStyle(Color.retroPurple)
                            .accessibilityLabel("Mark all Done sessions in this widget as reviewed").help("Mark all Done as reviewed")
                    }
                }.frame(height:header,alignment:.leading)
                if page.visible.isEmpty && capacity > 0 {
                    VStack(alignment:.leading,spacing:9) {
                        Text("No active sessions").font(retroFont(30*t))
                        Text(store.refreshing ? "Checking agent machines…" : "Open a session or connect another machine in the editor.").font(retroFont(21*t,bold:false))
                    }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
                } else {
                    ForEach(page.visible) { row in
                        agentRow(row,wide:wide,narrow:narrow,t:t).frame(height:rowHeight)
                            .background(row.completionPending ? Color.retroPurple.opacity(0.13) : .clear)
                            .overlay(alignment:.top) { Rectangle().fill(.black.opacity(0.35)).frame(height:0.8) }
                    }
                    Spacer(minLength:0)
                }
                HStack(spacing:10) {
                    if let overflow=page.overflowLabel { Text(overflow).font(retroFont(20*t)).foregroundStyle(page.hiddenAttentionCount > 0 ? .orange : .primary) }
                    if store.offlineCount > 0 && !store.document.previewMode { Text("\(store.offlineCount) offline").font(retroFont(18*t)).foregroundStyle(.orange) }
                    Spacer(minLength:0)
                }.frame(height:25*t).lineLimit(1)
            }.padding(.horizontal,narrow ? 10 : 14).padding(.top,3)
        }
    }
    @ViewBuilder func agentRow(_ row:SessionRow,wide:Bool,narrow:Bool,t:Double)->some View {
        HStack(spacing:narrow ? 8 : 12) {
            ProviderMark(provider:row.session.provider).frame(width:(wide ? 27 : 38)*t,height:(wide ? 27 : 38)*t)
            if wide {
                Text(row.session.title).font(retroFont(29*t)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                Text(metadata(row)).font(retroFont(21*t,bold:false)).lineLimit(1).frame(width:235*t,alignment:.leading)
                state(row,t:t,font:24).frame(width:218*t,alignment:.leading)
            } else if narrow {
                VStack(alignment:.leading,spacing:2) {
                    Text(row.session.title).font(retroFont(27*t)).lineLimit(1)
                    HStack(spacing:5) { state(row,t:t,font:20); Text(row.session.provider == "codex" ? "Codex" : "Claude").font(retroFont(18*t,bold:false)) }
                }.frame(maxWidth:.infinity,alignment:.leading)
            } else {
                VStack(alignment:.leading,spacing:1) {
                    Text(row.session.title).font(retroFont(29*t)).lineLimit(1)
                    Text(metadata(row)).font(retroFont(21*t,bold:false)).lineLimit(1)
                }.frame(maxWidth:.infinity,alignment:.leading)
                state(row,t:t,font:24).frame(width:218*t,alignment:.leading)
            }
        }.help("\(row.session.title)\n\(metadata(row))\n\(row.session.activity ?? row.session.state.label)\nLast activity: \(row.session.updatedAt.formatted(date:.abbreviated,time:.standard))")
    }
    func metadata(_ row:SessionRow)->String {
        let helper=row.session.isHelper || row.session.parentId != nil ? " · Helper" : ""
        return "\(row.session.provider == "codex" ? "Codex" : "Claude Code") · \(row.hostName)\(helper)"
    }
    func state(_ row:SessionRow,t:Double,font:Double)->some View {
        HStack(spacing:8) {
            StatusDot(state:row.session.state,connected:row.connected).frame(width:16*t,height:16*t)
            Text(row.connected ? row.session.state.label : "Offline").font(retroFont(font*t)).foregroundStyle(StatusDot(state:row.session.state,connected:row.connected).tint)
            if row.completionPending {
                Button { store.reviewCompletion(row) } label:{Text("Review").font(retroFont(17*t)).padding(.horizontal,5).frame(minHeight:30*t).overlay(Rectangle().stroke(Color.retroPurple,lineWidth:1))}
                    .buttonStyle(.plain).foregroundStyle(Color.retroPurple).accessibilityLabel("Mark \(row.session.title) done as reviewed").help("Mark done as reviewed")
            }
        }.lineLimit(1)
    }

}

struct MusicWidget: View {
    @ObservedObject var store:DashboardStore
    var body:some View {
        GeometryReader { geometry in
            let music=store.native.music
            let preview=store.document.previewMode
            let hasTrack=preview || music.hasTrack
            let t=store.document.textScale
            if hasTrack {
                let stacked=geometry.size.width < 300 && geometry.size.height/t >= 160
                let compact=geometry.size.height/t < (stacked ? 440 : 260)
                let artSize=stacked ? min(geometry.size.width-30,max(25,geometry.size.height-(compact ? 100 : 250)*t)) : min(geometry.size.height-24,geometry.size.width*0.43)
                let showArtist=geometry.size.height/t >= 95
                Group {
                    if stacked {
                        VStack(spacing:8) { artwork(preview:preview,url:music.artworkURL).frame(width:max(25,artSize),height:max(25,artSize)); details(preview:preview,compact:compact,t:t,showArtist:showArtist) }
                    } else {
                        HStack(spacing:16) { artwork(preview:preview,url:music.artworkURL).frame(width:max(25,artSize),height:max(25,artSize)); details(preview:preview,compact:compact,t:t,showArtist:showArtist) }
                    }
                }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                VStack(alignment:.leading,spacing:12) {
                    Text("Now Playing").font(retroFont(30*t))
                    Text(music.status).font(retroFont(22*t,bold:false))
                    if !store.native.musicEnabled { Button("Source settings…") { store.openSettings(.connections) }.buttonStyle(.bordered) }
                }.padding(15).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
            }
        }
    }
    @ViewBuilder func artwork(preview:Bool,url:URL?)->some View {
        if preview, let file=Bundle.module.url(forResource:"preview-artwork",withExtension:"png"),let image=NSImage(contentsOf:file) { Image(nsImage:image).resizable().scaledToFill().clipped() }
        else if let url,let image=NSImage(contentsOf:url) { Image(nsImage:image).resizable().scaledToFill().clipped() }
        else { Rectangle().fill(Color.retroPurple.opacity(0.22)).overlay(Image(systemName:"music.note").font(.system(size:48)).foregroundStyle(Color.retroPurple)) }
    }
    func details(preview:Bool,compact:Bool,t:Double,showArtist:Bool)->some View {
        VStack(alignment:.leading,spacing:compact ? 4 : 8) {
            Text(preview ? "Blue Hour" : store.native.music.title).font(retroFont((compact ? 27 : 32)*t)).lineLimit(compact ? 1 : 2)
            if showArtist { Text(preview ? "Paper Satellites" : store.native.music.artist).font(retroFont((compact ? 20 : 23)*t,bold:false)).lineLimit(1) }
            if !compact {
                Spacer(minLength:4)
                TimelineView(.periodic(from:.now,by:1)) { context in
                    let m=store.native.music
                    let position=preview ? 137.0 : min(m.duration,max(0,m.position+(m.isPlaying ? context.date.timeIntervalSince(m.updatedAt) : 0)))
                    let duration=preview ? 253.0 : m.duration
                    VStack(alignment:.leading,spacing:3) {
                        RetroProgress(fraction:duration>0 ? position/duration : 0,tint:.retroPurple).frame(height:13)
                        Text("\(clockTime(position)) / \(clockTime(duration))").font(retroFont(17*t,bold:false)).monospacedDigit()
                    }
                }
                HStack(spacing:20) {
                    playback("backward.end.fill",action:"previous")
                    playback(store.native.music.isPlaying || preview ? "pause.fill" : "play.fill",action:"playpause")
                    playback("forward.end.fill",action:"next")
                }.font(.system(size:22,weight:.bold)).padding(.top,3)
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
    }
    func playback(_ symbol:String,action:String)->some View { Button { if !store.document.previewMode { Task { await store.native.performPlayback(action) } } } label:{Image(systemName:symbol)}.buttonStyle(.plain).accessibilityLabel(action) }
    func clockTime(_ value:Double)->String { let n=Int(value.isFinite ? max(0,value) : 0);return String(format:"%d:%02d",n/60,n%60) }
}

struct RetroProgress: View {
    let fraction:Double;let tint:Color
    var body:some View { GeometryReader { g in ZStack(alignment:.leading) { Color.white;Rectangle().fill(tint).frame(width:g.size.width*min(1,max(0,fraction.isFinite ? fraction : 0))) }.overlay(Rectangle().stroke(.black,lineWidth:1.3)) } }
}
struct SystemWidget: View {
    @ObservedObject var store:DashboardStore
    let widget:DashboardWidget
    var body:some View {
        GeometryReader { g in
            let (_,value,connected)=store.system(for:widget)
            let t=store.document.textScale
            let items=readings(value)
            let layout=SystemMetricLayout(width:g.size.width,height:g.size.height,textScale:t,count:items.count)
            VStack(alignment:.leading,spacing:4) {
                if items.isEmpty {Text("Choose readings in Settings → Widgets.").font(retroFont(22*t,bold:false))}
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),alignment:.leading),count:layout.columns),alignment:.leading,spacing:8) {
                    ForEach(Array(items.prefix(layout.capacity).enumerated()),id:\.offset) {_,item in metric(item,t:t,compact:layout.compact)}
                }
                if items.count>layout.capacity {Text("+\(items.count-layout.capacity) more readings · resize to show").font(retroFont(17*t,bold:false)).lineLimit(1)}
            }.padding(8).opacity(connected ? 1 : 0.45).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
            if !connected {Text("Source unavailable").font(retroFont(18)).foregroundStyle(.orange).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomTrailing).padding(5)}
        }
    }
    func readings(_ value:SystemReading)->[(String,String,Double?)] {
        var result:[(String,String,Double?)]=[]
        if widget.systemOptions.showCPU {result.append(("CPU",value.cpuPercent.map{String(format:"%.0f%%",$0)} ?? "—",SystemMetricFraction.cpu(value.cpuPercent)))}
        if widget.systemOptions.showMemory {result.append(("RAM",bytes(value.memoryUsedBytes),memoryFraction(value)))}
        if widget.systemOptions.showStorage {
            result += store.selectedDrives(for:widget).map {drive in (drive.name.isEmpty ? drive.mountPoint : drive.name,bytes(drive.freeBytes)+" free",SystemMetricFraction.driveUsed(free:drive.freeBytes,total:drive.totalBytes))}
        }
        return result
    }
    func metric(_ item:(String,String,Double?),t:Double,compact:Bool)->some View {
        VStack(alignment:.leading,spacing:compact ? 3 : 4) {
            if compact {
                HStack(spacing:5) {
                    Text(item.0).font(retroFont(16*t)).lineLimit(1)
                    Text(item.1).font(retroFont(22*t)).lineLimit(1)
                }
            } else {
                Text(item.0).font(retroFont(18*t)).lineLimit(1)
                Text(item.1).font(retroFont(28*t)).lineLimit(1)
            }
            Group {
                if let fraction=item.2 { RetroProgress(fraction:fraction,tint:item.0 == "CPU" ? .retroPurple : .green) }
                else { Rectangle().fill(.clear).overlay(Rectangle().stroke(.black.opacity(0.4),lineWidth:1)).overlay(Text("—").font(.system(size:9))) }
            }.frame(height:compact ? 7 : 10)
                .help(item.2.map{String(format:"%.0f%% used",$0*100)} ?? "Usage unavailable")
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    func bytes(_ value:UInt64?)->String {value.map{ByteCountFormatter.string(fromByteCount:Int64(clamping:$0),countStyle:.memory)} ?? "—"}
    func memoryFraction(_ value:SystemReading)->Double? {SystemMetricFraction.used(value.memoryUsedBytes,total:value.memoryTotalBytes)}
}
struct ClockWidget:View {
    var textScale:Double
    var body:some View {
        GeometryReader { g in
            let showDate=g.size.height/textScale >= 145
            let font=min((g.size.height-(showDate ? 58*textScale : 24))*0.75,g.size.width*0.19)
            TimelineView(.periodic(from:.now,by:1)) { context in
                VStack(alignment:.leading,spacing:4) {
                    Text(context.date.formatted(date:.omitted,time:.shortened)).font(retroFont(max(25,font))).monospacedDigit().lineLimit(1)
                    if showDate {Text(context.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).font(retroFont(25*textScale)).lineLimit(1)}
                }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
            }
        }
    }
}
struct WeatherWidget:View {
    @ObservedObject var store:DashboardStore
    let widget:DashboardWidget
    var body:some View {
        GeometryReader { g in
            let info=store.native.weather(for:widget)
            let preview=store.document.previewMode
            let temp=preview ? 18.0 : info.temperature
            let t=store.document.textScale
            let compact=g.size.height/t < 100
            if let temp {
                HStack(spacing:12) {
                    Image(systemName:preview ? "cloud.sun.fill" : info.symbol).symbolRenderingMode(.palette).foregroundStyle(.gray,.yellow).font(.system(size:compact ? min(36,g.size.height-18) : min(58,(g.size.height-16)*0.65)))
                    if compact {
                        Text("\(Int(temp.rounded()))°").font(retroFont(min(40*t,max(24,(g.size.height-16)*0.7))))
                        if g.size.width/t > 400 {Text(preview ? "Partly cloudy" : info.condition).font(retroFont(21*t)).lineLimit(1)}
                    } else {
                        VStack(alignment:.leading,spacing:0) {
                            Text("\(Int(temp.rounded()))°").font(retroFont(min(64*t,(g.size.height-48)*0.8)))
                            Text(preview ? "Partly cloudy" : info.condition).font(retroFont(21*t)).lineLimit(1)
                            if g.size.height/t > 150 {Text(info.place).font(retroFont(20*t,bold:false)).lineLimit(1)}
                        }
                    }
                }.padding(8).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
                if !preview && info.status != "Open-Meteo" {Text("Offline").font(retroFont(16)).foregroundStyle(.orange).padding(5).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topTrailing).help(info.status)}
            } else {
                VStack(alignment:.leading,spacing:5) {
                    if g.size.height>100 {Text("Weather").font(retroFont(27*t))}
                    Text(info.status).font(retroFont(20*t,bold:false)).lineLimit(g.size.height>110 ? 2 : 1)
                    if g.size.height>90 {Button("Configure Weather…"){store.configure(widget.id)}.buttonStyle(.bordered).accessibilityLabel("Configure this Weather widget")}
                }.padding(9).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
            }
        }
    }
}
struct CalendarWidget:View {
    @ObservedObject var store:DashboardStore
    let widget:DashboardWidget
    var body:some View {
        GeometryReader { g in
            let t=store.document.textScale
            let events=store.calendarEvents(for:widget)
            let first=events.first
            if let first {
                if g.size.height/t < 115 {
                    HStack(spacing:10) {
                        Text(first.compactDateLabel()).font(retroFont(min(22*t,g.size.height-24),bold:false)).fixedSize()
                        Text(first.title).font(retroFont(min(27*t,g.size.height-24))).lineLimit(1)
                    }.padding(8).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
                } else {
                    VStack(alignment:.leading,spacing:10) {
                        calendarRow(first,t:t,height:g.size.height)
                        if g.size.height/t>250 && !store.document.previewMode {
                            ForEach(Array(events.dropFirst().prefix(2))) {event in Text("\(event.startDate.formatted(date:.abbreviated,time:.shortened)) · \(event.title)").font(retroFont(21*t,bold:false)).lineLimit(1)}
                        }
                    }.padding(8)
                }
            } else {
                VStack(alignment:.leading,spacing:7) {
                    if g.size.height>100 {Text(store.native.calendar.authorized ? "No upcoming events" : "Calendar").font(retroFont(27*t))}
                    Text(store.native.calendar.authorized ? "No events match this widget’s selection" : store.native.calendar.status).font(retroFont(20*t,bold:false)).lineLimit(g.size.height>100 ? 2 : 1)
                    if !store.native.calendar.authorized && g.size.height>85 {Button("Source settings…"){store.openSettings(.connections)}.buttonStyle(.bordered)}
                }.padding(9).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
            }
        }
    }
    func calendarRow(_ event:CalendarEntry,t:Double,height:Double)->some View {
        VStack(alignment:.leading,spacing:4) {
                Text(event.startDate.formatted(date:.abbreviated,time:event.isAllDay ? .omitted : .shortened)).font(retroFont(23*t,bold:false)).lineLimit(1)
                Text(event.title).font(retroFont(34*t)).lineLimit(height/t>145 ? 2 : 1)
                if height/t>180 && !event.calendarTitle.isEmpty { Text(event.calendarTitle).font(retroFont(18*t,bold:false)).foregroundStyle(.secondary).lineLimit(1) }
        }.padding(8).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
    }
}
