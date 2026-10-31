import Foundation

/// Prefers a single row of readouts, with readable inline fallbacks and honest overflow.
public struct SystemMetricLayout: Equatable, Sendable {
    public let columns:Int
    public let capacity:Int
    public let compact:Bool
    public let columnar:Bool
    public let padding:Double
    public let spacing:Double
    public let horizontalSpacing:Double
    public let rowHeight:Double
    public let overflowHeight:Double
    public init(width:Double,height:Double,textScale:Double,count:Int,minimumColumnWidth:Double=118) {
        let scale=max(0.8,textScale.isFinite ? textScale : 1)
        let w=max(0,width.isFinite ? width : 0)
        let h=max(0,height.isFinite ? height : 0)
        let total=max(0,count)
        // A column budgets the actual 18pt label, 26pt value and 5pt gauge.
        // Use this presentation only when every requested reading fits comfortably.
        let columnSpacing=12.0
        let columnHeight=66*scale
        let columnWidth=max(118,minimumColumnWidth.isFinite ? minimumColumnWidth : 118)*scale
        if total>0 && w>=16+Double(total)*columnWidth+Double(total-1)*columnSpacing && h>=16+columnHeight {
            columnar=true;compact=false;columns=total;capacity=total
            padding=8;spacing=8;horizontalSpacing=columnSpacing
            rowHeight=columnHeight;overflowHeight=20*scale
            return
        }
        columnar=false
        let normalColumns=max(1,min(max(1,total),Int(max(0,w-16+8)/(210*scale+8))))
        let normalRows=max(0,Int(max(0,h-16+8)/(72*scale+8)))
        compact=normalRows*normalColumns<total || normalRows==0
        padding=compact ? 6 : 8
        spacing=compact ? 4 : 8
        horizontalSpacing=compact ? 14 : 8
        rowHeight=(compact ? 33 : 72)*scale
        overflowHeight=20*scale
        columns=compact ? max(1,min(max(1,total),Int(max(0,w-2*padding+horizontalSpacing)/(210*scale+horizontalSpacing)))) : normalColumns
        let available=max(0,h-2*padding)
        var rows=max(0,Int((available+spacing)/(rowHeight+spacing)))
        if total>rows*columns {
            rows=max(0,Int(max(0,available-overflowHeight)/(rowHeight+spacing)))
        }
        capacity=rows*columns
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
