import Foundation

/// Fits complete readouts first, using both dimensions and measured text widths.
public struct SystemMetricLayout: Equatable, Sendable {
    public let columns:Int
    public let capacity:Int
    public let compact:Bool
    public let columnar:Bool
    public let stackedCompact:Bool
    public let labelLineLimit:Int
    public let padding:Double
    public let spacing:Double
    public let horizontalSpacing:Double
    public let rowHeight:Double
    public let overflowHeight:Double
    public let statusHeight:Double

    public init(width:Double,height:Double,textScale:Double,count:Int,minimumColumnWidth:Double=118,
                minimumWrappedColumnWidth:Double?=nil,minimumInlineWidth:Double=210,minimumCompactColumnWidth:Double?=nil,sourceAvailable:Bool=true) {
        let scale=max(0.8,textScale.isFinite ? textScale : 1)
        let w=max(0,width.isFinite ? width : 0),totalHeight=max(0,height.isFinite ? height : 0)
        statusHeight=sourceAvailable ? 0 : min(totalHeight,26*scale)
        let h=totalHeight-statusHeight
        let total=max(0,count)
        struct Choice {
            var columns:Int;var capacity:Int;var rows:Int;var mode:Int
            var padding:Double;var spacing:Double;var horizontalSpacing:Double
            var rowHeight:Double;var overflowHeight:Double;var score:Double
        }
        func choices(mode:Int,partial:Bool,allowNarrow:Bool=false)->[Choice] {
            if mode == 1 && minimumWrappedColumnWidth == nil {return []}
            if mode == 2 && minimumCompactColumnWidth == nil {return []}
            let widthRequirement=mode == 0 ? minimumColumnWidth : (mode == 1 ? minimumWrappedColumnWidth! : (mode == 2 ? minimumCompactColumnWidth! : minimumInlineWidth))
            let minimumWidth=max(118,widthRequirement.isFinite ? widthRequirement : 118)*scale
            let pad=min(mode >= 2 ? 6.0 : 8.0,w/2,h/2)
            let available=max(0,h-pad*2)
            let horizontal=mode >= 2 ? 14.0 : 12.0
            var result:[Choice]=[]
            for cols in 1...max(1,total) {
                let cellWidth=(w-pad*2-Double(cols-1)*horizontal)/Double(cols)
                guard cellWidth>=minimumWidth || (allowNarrow && cols == 1) else {continue}
                let needed=total == 0 ? 0 : (total-1)/cols+1
                let minHeight=(mode == 3 ? 33.0 : (mode == 2 ? 49.0 : (mode == 1 ? 88.0 : (needed == 1 ? 66.0 : 60.0))))*scale
                let footer=partial && total>0 ? min(20*scale,available) : 0
                let gap=min(4.0,max(0,available-footer))
                let budget=max(0,available-(partial ? footer+gap : 0))
                let fitting=Int(min(Double(total),max(0,((budget+gap)/(minHeight+gap)).rounded(.down))))
                let shown=partial ? min(total,fitting*cols) : total
                let rows=shown == 0 ? 0 : (shown-1)/cols+1
                guard partial || fitting>=needed else {continue}
                let height=rows>0 ? (budget-Double(rows-1)*gap)/Double(rows) : minHeight
                let aspect=cellWidth/max(1,height)
                let empty=rows*cols-shown
                let score=abs(log(max(0.01,aspect)/2.5))+Double(empty)*0.2
                result.append(Choice(columns:cols,capacity:shown,rows:rows,mode:mode,padding:pad,spacing:gap,
                                     horizontalSpacing:horizontal,rowHeight:height,overflowHeight:footer,score:score))
            }
            return result
        }
        var selected:Choice?
        // Prefer full-size headings, then wrapped headings, then compact stacked tiles and inline rows.
        for mode in 0...3 {
            if let best=choices(mode:mode,partial:false).min(by:{$0.score<$1.score}) {selected=best;break}
        }
        if selected == nil {
            let partial=(0...3).flatMap{choices(mode:$0,partial:true)}
            selected=partial.min {
                if $0.capacity != $1.capacity {return $0.capacity>$1.capacity}
                if $0.mode != $1.mode {return $0.mode<$1.mode}
                return $0.score<$1.score
            }
        }
        // A single narrow readout can still show its value with a wrapped heading.
        if selected == nil {
            selected=choices(mode:minimumWrappedColumnWidth == nil ? 0 : 1,partial:true,allowNarrow:true).first
        }
        let choice=selected!
        columns=choice.columns;capacity=choice.capacity
        stackedCompact=choice.mode == 2
        compact=choice.mode >= 2;columnar=choice.mode == 1 || (!compact && choice.rows == 1 && choice.capacity == total)
        labelLineLimit=choice.mode == 1 ? 2 : 1
        padding=choice.padding;spacing=choice.spacing;horizontalSpacing=choice.horizontalSpacing
        rowHeight=choice.rowHeight;overflowHeight=choice.overflowHeight
    }
}
public enum SystemMetricFraction {
    public static func cpu(_ value:Double?) -> Double? {
        guard let value,value.isFinite,(0...100).contains(value) else {return nil}
        return value/100
    }
    public static func used(_ used:UInt64?,total:UInt64?) -> Double? {
        guard let used,let total,total>0,used<=total else {return nil}
        return Double(used)/Double(total)
    }
    public static func driveUsed(free:UInt64?,total:UInt64?) -> Double? {
        guard let free,let total,total>0,free<=total else {return nil}
        return Double(total-free)/Double(total)
    }
}

/// App-side labels also clarify readings supplied by older collectors.
public enum SystemDrivePresentation {
    public static func isStartup(_ drive:DriveReading)->Bool { drive.id == "/" || drive.mountPoint == "/" }
    public static func label(for drive:DriveReading)->String {
        if isStartup(drive) {return "Startup disk"}
        let name=drive.name.trimmingCharacters(in:.whitespacesAndNewlines)
        return name.isEmpty ? URL(fileURLWithPath:drive.mountPoint).lastPathComponent : name
    }
    public static func detail(for drive:DriveReading)->String {
        "\(drive.name.isEmpty ? label(for:drive) : drive.name) · \(drive.mountPoint)"
    }
}
