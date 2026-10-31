import Foundation

/// Chooses readable two-line or inline metrics before reserving honest overflow space.
public struct SystemMetricLayout: Equatable, Sendable {
    public let columns:Int
    public let capacity:Int
    public let compact:Bool
    public let padding:Double
    public let spacing:Double
    public let horizontalSpacing:Double
    public let rowHeight:Double
    public let overflowHeight:Double
    public init(width:Double,height:Double,textScale:Double,count:Int) {
        let scale=max(0.8,textScale.isFinite ? textScale : 1)
        let w=max(0,width.isFinite ? width : 0)
        let h=max(0,height.isFinite ? height : 0)
        let total=max(0,count)
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
