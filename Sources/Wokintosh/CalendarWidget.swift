import SwiftUI
import WokintoshCore

struct CalendarWidget:View {
    @ObservedObject var store:DashboardStore
    let widget:DashboardWidget
    var body:some View {
        GeometryReader { g in
            let t=store.document.textScale
            let events=store.calendarEvents(for:widget)
            if let first=events.first {
                if g.size.height/t<70 {
                    HStack(spacing:8) {
                        Text(first.compactDateLabel()).font(retroFont(18*t,bold:false)).fixedSize()
                        Text(first.title).font(retroFont(26*t)).lineLimit(1)
                    }.padding(6).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
                        .help(eventHelp(first))
                } else {
                    VStack(alignment:.leading,spacing:8) {
                        calendarRow(first,t:t,height:g.size.height)
                        if g.size.height/t>250 && !store.document.previewMode {
                            ForEach(Array(events.dropFirst().prefix(2))) { event in
                                Text("\(event.compactDateLabel()) · \(event.title)").font(retroFont(21*t,bold:false)).lineLimit(1).help(eventHelp(event))
                            }
                        }
                    }.padding(6).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                }
            } else {
                VStack(alignment:.leading,spacing:6) {
                    if g.size.height>100 {Text(store.native.calendar.authorized ? "No upcoming events" : "Calendar").font(retroFont(27*t))}
                    Text(store.native.calendar.authorized ? "No events match this widget’s selection" : store.native.calendar.status).font(retroFont(20*t,bold:false)).lineLimit(g.size.height>100 ? 2 : 1)
                    if !store.native.calendar.authorized && g.size.height>85 {Button("Source settings…"){store.openSettings(.connections)}.buttonStyle(.bordered)}
                }.padding(8).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
            }
        }
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
