import Foundation

public enum WidgetInteraction {
    public static func moving(_ start: WidgetFrame, dx: Double, dy: Double, snap: Bool) -> WidgetFrame {
        let x=quantize(start.x*1280+dx,snap:snap)/1280
        let y=quantize(start.y*682+dy,snap:snap)/682
        return WidgetFrame(x:min(1-start.width,max(0,x)),y:min(1-start.height,max(0,y)),width:start.width,height:start.height)
    }
    public static func resizing(_ start: WidgetFrame, dx: Double, dy: Double, kind: WidgetKind, snap: Bool) -> WidgetFrame {
        let proposed=WidgetFrame(x:start.x,y:start.y,width:quantize(start.width*1280+dx,snap:snap)/1280,height:quantize(start.height*682+dy,snap:snap)/682).clamped(for:kind)
        return WidgetFrame(x:start.x,y:start.y,width:min(1-start.x,proposed.width),height:min(1-start.y,proposed.height))
    }
    private static func quantize(_ value: Double, snap: Bool) -> Double {
        guard value.isFinite else { return 0 }
        return snap ? (value/16).rounded()*16 : value
    }
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
