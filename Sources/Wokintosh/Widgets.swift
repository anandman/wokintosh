import SwiftUI
import WokintoshCore

struct WidgetContent: View {
    @ObservedObject var store: DashboardStore
    let widget: DashboardWidget
    var editing=false
    var body: some View {
        Group {
            switch widget.kind {
            case .agents: AgentWidget(store:store,widget:widget,actionsEnabled:!editing)
            case .music: MusicWidget(store:store,widget:widget,actionsEnabled:!editing)
            case .system: WidgetActionArea(store:store,widget:widget,enabled:!editing) {SystemWidget(store:store,widget:widget).frame(maxWidth:.infinity,maxHeight:.infinity)}
            case .clock: WidgetActionArea(store:store,widget:widget,enabled:!editing) {ClockWidget(textScale:store.document.textScale).frame(maxWidth:.infinity,maxHeight:.infinity)}
            case .weather: WeatherWidget(store:store,widget:widget,actionsEnabled:!editing)
            case .calendar: CalendarWidget(store:store,widget:widget,actionsEnabled:!editing)
            }
        }.clipped()
    }
}

struct RetroProgress: View {
    let fraction:Double;let tint:Color
    var body:some View { GeometryReader { g in ZStack(alignment:.leading) { Color.white;Rectangle().fill(tint).frame(width:g.size.width*min(1,max(0,fraction.isFinite ? fraction : 0))) }.overlay(Rectangle().stroke(.black,lineWidth:1.3)) } }
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
    var actionsEnabled=true
    var body:some View {
        GeometryReader { g in
            let info=store.native.weather(for:widget)
            let preview=store.document.previewMode
            let temp=preview ? 18.0 : info.temperature
            let t=store.document.textScale
            let compact=g.size.height/t < 90
            if let temp {
                WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled) {
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
                }
                if !preview && info.status != "Open-Meteo" {Text("Offline").font(retroFont(16)).foregroundStyle(.orange).padding(5).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topTrailing).help(info.status)}
            } else {
                VStack(alignment:.leading,spacing:5) {
                    WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled) {
                        VStack(alignment:.leading,spacing:5) {
                            if g.size.height>100 {Text("Weather").font(retroFont(27*t))}
                            Text(info.status).font(retroFont(20*t,bold:false)).lineLimit(g.size.height>110 ? 2 : 1)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                    if g.size.height>90 {Button("Configure Weather…"){store.configure(widget.id)}.buttonStyle(.bordered).accessibilityLabel("Configure this Weather widget")}
                }.padding(9).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
            }
        }
    }
}
