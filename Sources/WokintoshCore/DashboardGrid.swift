import Foundation

/// Coordinates are relative to the desktop below the 38-point menu bar.
public enum DashboardGrid {
    public static let step = 16.0
    public static let width = 1280.0
    public static let height = 682.0

    /// Explicit alignment may move a custom origin so every edge and minimum fits the grid.
    public static func snappedFrame(_ frame: WidgetFrame, kind: WidgetKind) -> WidgetFrame {
        let safe = frame.clamped(for: kind)
        let minimum = WidgetFrame.minimumSize(for: kind)
        let w = min(down(width), max(up(minimum.width * width), nearest(safe.width * width)))
        let h = min(down(height), max(up(minimum.height * height), nearest(safe.height * height)))
        let x = position(safe.x * width, extent: w, limit: width)
        let y = position(safe.y * height, extent: h, limit: height)
        return normalizedFrame(x: x, y: y, width: w, height: h)
    }

    static func normalizedFrame(x: Double, y: Double, width: Double, height: Double) -> WidgetFrame {
        WidgetFrame(x: x / self.width, y: y / self.height, width: width / self.width, height: height / self.height)
    }

    static func nearest(_ value: Double) -> Double { (finite(value) / step).rounded() * step }
    private static func up(_ value: Double) -> Double { (finite(value) / step).rounded(.up) * step }
    private static func down(_ value: Double) -> Double { (finite(value) / step).rounded(.down) * step }
    private static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

    static func position(_ value: Double, extent: Double, limit: Double) -> Double {
        min(max(0, down(limit - extent)), max(0, nearest(value)))
    }

    /// The origin remains anchored, including a legacy off-grid origin. Snap the absolute edge.
    static func resizedExtent(_ value: Double, origin: Double, minimum: Double, limit: Double) -> Double {
        let maximumEdge = down(limit)
        let minimumEdge = up(origin + minimum)
        // A legacy anchor can leave no grid endpoint that preserves its readable minimum.
        // Keep the anchor, minimum and canvas bounds; explicit alignment can move the anchor.
        if minimumEdge > maximumEdge {
            return max(0, min(limit, max(origin + minimum, nearest(value))) - origin)
        }
        let edge = min(maximumEdge, max(minimumEdge, nearest(value)))
        return max(0, edge - origin)
    }

    static func defaultFrame(for kind: WidgetKind) -> WidgetFrame? {
        switch kind {
        case .agents: return normalizedFrame(x: 16, y: 16, width: 752, height: 496)
        case .music: return normalizedFrame(x: 784, y: 16, width: 480, height: 304)
        case .calendar: return normalizedFrame(x: 784, y: 336, width: 480, height: 176)
        case .weather: return normalizedFrame(x: 16, y: 528, width: 352, height: 128)
        case .system: return normalizedFrame(x: 384, y: 528, width: 880, height: 128)
        case .clock: return nil
        }
    }

    static func legacyDefaultFrame(for kind: WidgetKind) -> WidgetFrame? {
        switch kind {
        case .agents: return WidgetFrame(x: 0.018, y: 0.025, width: 0.59, height: 0.72)
        case .music: return WidgetFrame(x: 0.625, y: 0.025, width: 0.36, height: 0.44)
        case .calendar: return WidgetFrame(x: 0.625, y: 0.49, width: 0.36, height: 0.255)
        case .weather: return WidgetFrame(x: 0.018, y: 0.78, width: 0.27, height: 0.195)
        case .system: return WidgetFrame(x: 0.305, y: 0.78, width: 0.68, height: 0.195)
        case .clock: return nil
        }
    }
}
