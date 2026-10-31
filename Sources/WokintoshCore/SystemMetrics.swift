import Foundation

/// Layout budgets include a gauge in every size, including a one-row widget.
public struct SystemMetricLayout: Equatable, Sendable {
    public let columns:Int
    public let capacity:Int
    public let compact:Bool
    public init(width:Double,height:Double,textScale:Double,count:Int) {
        let scale=max(0.8,textScale.isFinite ? textScale : 1)
        columns=max(1,min(max(1,count),Int(max(0,width-16)/(215*scale))))
        compact=height/scale<82
        let rowHeight=(compact ? 39.0 : 72.0)*scale
        let available=max(0,height-16)
        var rows=max(1,Int((available+8)/(rowHeight+8)))
        if count>rows*columns { rows=max(1,Int(max(0,available-23*scale+8)/(rowHeight+8))) }
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
