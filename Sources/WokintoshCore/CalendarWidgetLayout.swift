import Foundation

public struct CalendarWidgetLayout: Equatable, Sendable {
    public enum Style: Sendable { case detail, agenda, stackedAgenda }
    public let style:Style
    public let visibleCount:Int
    public let rowHeight:Double
    public let spacing:Double
    public let padding:Double
    public let eventCount:Int
    public var suffix:String {eventCount>1 ? "\(visibleCount)/\(eventCount)" : ""}
    public init(width:Double,height:Double,textScale:Double,eventCount:Int,nextEventOnly:Bool) {
        let scale=max(0.8,textScale.isFinite ? textScale : 1)
        self.eventCount=max(0,eventCount)
        let w=max(0,width.isFinite ? width : 0)
        let h=max(0,height.isFinite ? height : 0)
        padding=6;spacing=4
        let wide=w/scale>=460
        rowHeight=(wide ? 32:56)*scale
        let capacity=max(0,Int(max(0,h-padding*2+spacing)/(rowHeight+spacing)))
        if !nextEventOnly && eventCount>1 && capacity>=2 {
            style=wide ? .agenda:.stackedAgenda
            visibleCount=min(max(0,eventCount),capacity)
        } else {
            style = .detail
            visibleCount=min(max(0,eventCount),1)
        }
    }
}
