import SwiftUI
import WokintoshCore

struct CalendarWidget:View {
    @ObservedObject var store:DashboardStore
    let widget:DashboardWidget
    var actionsEnabled=true
    var body:some View {
        let presentation=store.calendarSource(for:widget)
        NativeWidgetSourceFrame(source:presentation.source,textScale:store.document.textScale) { size in
            calendarContent(size:size,presentation:presentation)
        }
    }
    @ViewBuilder private func calendarContent(size:CGSize,presentation:CalendarSourcePresentation)->some View {
        let t=store.document.textScale
        let events=store.calendarEvents(for:widget)
        let font=NSFont(name:"ArialMT",size:18*t) ?? NSFont.systemFont(ofSize:18*t)
        let dateWidth=min(max(0,size.width-12)*0.4,(events.map {($0.compactDateLabel() as NSString).size(withAttributes:[.font:font]).width}.max() ?? 0)+2)
        let layout=CalendarWidgetLayout(width:size.width,height:size.height,textScale:t,eventCount:events.count,nextEventOnly:widget.calendarOptions.nextEventOnly)
        if let first=events.first {
            WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled) {
            if layout.style != .detail {
                VStack(alignment:.leading,spacing:layout.spacing) {
                    ForEach(Array(events.prefix(layout.visibleCount).enumerated()),id:\.element.id) { index,event in
                        agendaRow(event,t:t,stacked:layout.style == .stackedAgenda,dateWidth:dateWidth)
                            .frame(height:layout.rowHeight)
                            .overlay(alignment:.top) {if index>0 {Rectangle().fill(.black.opacity(0.18)).frame(height:0.5)}}
                    }
                }.padding(layout.padding).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            } else if size.height/t<44 {
                Text(first.title).font(retroFont(20*t)).lineLimit(1).padding(.horizontal,6)
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).help(eventHelp(first))
            } else if size.height/t<70 {
                HStack(spacing:8) {
                    Text(first.compactDateLabel()).font(retroFont(18*t,bold:false)).fixedSize()
                    Text(first.title).font(retroFont(26*t)).lineLimit(1)
                }.padding(6).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
                    .help(eventHelp(first))
            } else {
                VStack(alignment:.leading,spacing:8) {
                    calendarRow(first,t:t,height:size.height)
                }.padding(6).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            }
            }
        } else {
            VStack(alignment:.leading,spacing:6) {
                WidgetActionArea(store:store,widget:widget,enabled:actionsEnabled) {
                    VStack(alignment:.leading,spacing:6) {
                        if size.height>100 {Text(presentation.loading ? "Loading Calendar…" : (presentation.info.authorized && !presentation.loading ? "No upcoming events" : "Calendar")).font(retroFont(27*t))}
                        Text(presentation.info.authorized && !presentation.loading ? "No events match this widget’s selection" : presentation.info.status).font(retroFont(20*t,bold:false)).lineLimit(size.height>100 ? 2 : 1)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
                if !presentation.info.authorized && size.height>85 {
                    Button(presentation.source == nil ? "Source settings…" : "Manage Machines…") {store.openSettings(presentation.source == nil ? .connections : .machines)}.buttonStyle(.bordered)
                }
            }.padding(8).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
        }
    }
    @ViewBuilder private func agendaRow(_ event:CalendarEntry,t:Double,stacked:Bool,dateWidth:Double)->some View {
        Group {
            if stacked {
                VStack(alignment:.leading,spacing:2) {
                    Text(event.compactDateLabel()).font(retroFont(18*t,bold:false)).lineLimit(1)
                    Text(event.title).font(retroFont(24*t)).lineLimit(1)
                }.frame(maxWidth:.infinity,alignment:.leading)
            } else {
                HStack(spacing:10) {
                    Text(event.compactDateLabel()).font(retroFont(18*t,bold:false)).lineLimit(1).frame(width:dateWidth,alignment:.leading)
                    Text(event.title).font(retroFont(24*t)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                }
            }
        }.help(eventHelp(event)).accessibilityElement(children:.combine)
    }
    private func calendarRow(_ event:CalendarEntry,t:Double,height:Double)->some View {
        let compact=height/t<125
        let titleSize=compact ? 26.0 : 32.0
        let lines=max(1,min(2,Int(max(0,height/t-37.2)/(titleSize*1.16))))
        return VStack(alignment:.leading,spacing:2) {
            Text(event.compactDateLabel()).font(retroFont(20*t,bold:false)).lineLimit(1)
            Text(event.title).font(retroFont(titleSize*t)).lineLimit(lines)
                .frame(maxWidth:.infinity,alignment:.leading)
            if height/t>180 && !event.calendarTitle.isEmpty {
                Text(event.calendarTitle).font(retroFont(18*t,bold:false)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).help(eventHelp(event))
    }
    private func eventHelp(_ event:CalendarEntry)->String {
        event.title+"\n"+event.startDate.formatted(date:.abbreviated,time:event.isAllDay ? .omitted : .shortened)+(event.calendarTitle.isEmpty ? "" : "\n"+event.calendarTitle)
    }
}
