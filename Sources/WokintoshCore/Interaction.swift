import Foundation

public enum WidgetInteraction {
    public static func moving(_ start: WidgetFrame, dx: Double, dy: Double, snap: Bool) -> WidgetFrame {
        let proposedX = start.x * DashboardGrid.width + dx
        let proposedY = start.y * DashboardGrid.height + dy
        let x = snap ? DashboardGrid.position(proposedX, extent: start.width * DashboardGrid.width, limit: DashboardGrid.width) / DashboardGrid.width : finite(proposedX) / DashboardGrid.width
        let y = snap ? DashboardGrid.position(proposedY, extent: start.height * DashboardGrid.height, limit: DashboardGrid.height) / DashboardGrid.height : finite(proposedY) / DashboardGrid.height
        return WidgetFrame(x: min(1-start.width, max(0,x)), y: min(1-start.height, max(0,y)), width: start.width, height: start.height)
    }
    public static func resizing(_ start: WidgetFrame, dx: Double, dy: Double, kind: WidgetKind, snap: Bool) -> WidgetFrame {
        if snap {
            let minimum = WidgetFrame.minimumSize(for: kind)
            let x = start.x * DashboardGrid.width
            let y = start.y * DashboardGrid.height
            let width = DashboardGrid.resizedExtent(x + start.width * DashboardGrid.width + dx, origin: x, minimum: minimum.width * DashboardGrid.width, limit: DashboardGrid.width)
            let height = DashboardGrid.resizedExtent(y + start.height * DashboardGrid.height + dy, origin: y, minimum: minimum.height * DashboardGrid.height, limit: DashboardGrid.height)
            return WidgetFrame(x: start.x, y: start.y, width: width / DashboardGrid.width, height: height / DashboardGrid.height)
        }
        let proposed = WidgetFrame(x: start.x, y: start.y, width: finite(start.width * DashboardGrid.width + dx) / DashboardGrid.width, height: finite(start.height * DashboardGrid.height + dy) / DashboardGrid.height).clamped(for: kind)
        return WidgetFrame(x: start.x, y: start.y, width: min(1-start.x, proposed.width), height: min(1-start.y, proposed.height))
    }
    private static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
}

public struct SystemWidgetOptions: Codable, Equatable, Sendable {
    public var showCPU = true
    public var showMemory = true
    public var showStorage = true
    /// nil uses the home/startup volume; empty selects no drives. IDs are mount points.
    public var driveIDs: [String]? = nil
    public init() {}
}

public struct DriveReading: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var mountPoint: String
    public var freeBytes: UInt64?
    public var totalBytes: UInt64?
    public init(id: String, name: String, mountPoint: String, freeBytes: UInt64? = nil, totalBytes: UInt64? = nil) {
        self.id=id;self.name=name;self.mountPoint=mountPoint;self.freeBytes=freeBytes;self.totalBytes=totalBytes
    }
}
