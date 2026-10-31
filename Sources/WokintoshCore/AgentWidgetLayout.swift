import Foundation

/// Row and surrounding text use the same budget at every text scale.
public struct AgentWidgetLayout: Equatable, Sendable {
    public let singleLine: Bool
    public let narrow: Bool
    public let compactSummary: Bool
    public let rowHeight: Double
    public let headerHeight: Double
    public let footerHeight: Double
    public let capacity: Int
    public init(width: Double, height: Double, textScale: Double) {
        let t=max(0.8,textScale.isFinite ? textScale : 1)
        let w=max(0,width.isFinite ? width : 0)
        let h=max(0,height.isFinite ? height : 0)
        singleLine=w/t>=650
        narrow=w/t<440
        rowHeight=(singleLine ? 42 : (narrow ? 60 : 54))*t
        footerHeight=24*t
        compactSummary=narrow && h<54*t+footerHeight+3
        headerHeight=(compactSummary ? 28 : (narrow ? 54 : 36))*t
        capacity=max(0,Int((h-headerHeight-footerHeight-3)/rowHeight))
    }
}
