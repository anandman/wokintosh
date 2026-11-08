import Foundation

public enum SetupExportKind:String,Codable,Sendable { case setup,template }

/// Collector identity is independent of a remote connection's configuration UUID.
public struct SetupMachineReference:Codable,Equatable,Identifiable,Sendable {
    public var id:String
    public var name:String
    public var isLocal:Bool
    public var remoteHostID:UUID?
    public init(id:String,name:String,isLocal:Bool=false,remoteHostID:UUID?=nil) {
        self.id=id;self.name=name;self.isLocal=isLocal;self.remoteHostID=remoteHostID
    }
}

public enum SetupTransferError:LocalizedError {
    case oversized,unsupported,duplicateIDs,invalidMachine
    public var errorDescription:String? {
        switch self {
        case .oversized:return "Setup files must be no larger than 16 MiB."
        case .unsupported:return "This is not a supported Wokintosh setup file."
        case .duplicateIDs:return "The setup contains duplicate widget or machine identifiers."
        case .invalidMachine:return "The setup contains an invalid machine connection or reference."
        }
    }
}

/// An allowlist of portable settings; runtime records and device preferences cannot leak in.
public struct DashboardSetup:Codable,Equatable,Sendable {
    public static let maximumBytes=16*1024*1024
    public var format:String
    public var version:Int
    public var kind:SetupExportKind
    public var widgets:[Widget]
    public var textScale:Double
    public var snapToGrid:Bool
    public var remoteHosts:[RemoteHost]
    public var machines:[SetupMachineReference]

    public static func export(document:DashboardDocument,kind:SetupExportKind,machines:[SetupMachineReference]=[])->DashboardSetup {
        let referenced=Set(document.widgets.compactMap(\.hostID))
        let result=DashboardSetup(format:"dev.wokintosh.setup",version:1,kind:kind,widgets:document.widgets,
                                  textScale:document.textScale,snapToGrid:document.snapToGrid,
                                  remoteHosts:document.remoteHosts,machines:machines.filter{referenced.contains($0.id)})
        return kind == .template ? result.sanitizedTemplate() : result
    }

    public func encoded() throws -> Data {
        let safe=kind == .template ? sanitizedTemplate() : self
        try safe.validate()
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let data=try encoder.encode(safe)
        guard data.count<=Self.maximumBytes else {throw SetupTransferError.oversized}
        return data
    }

    public static func decode(_ data:Data) throws -> DashboardSetup {
        guard data.count<=maximumBytes else {throw SetupTransferError.oversized}
        let result=try JSONDecoder().decode(Self.self,from:data)
        try result.validate()
        return result.kind == .template ? result.sanitizedTemplate() : result
    }

    public func defaultMachineMapping(localHostID:String?)->[String:String] {
        guard let localHostID,!localHostID.isEmpty else {return [:]}
        return Dictionary(uniqueKeysWithValues:machines.filter(\.isLocal).map{($0.id,localHostID)})
    }

    public func applying(to destination:DashboardDocument,machineMapping:[String:String]=[:]) throws -> DashboardDocument {
        try validate()
        let source=kind == .template ? sanitizedTemplate() : self
        var result=destination
        result.widgets=source.widgets.map { widget in
            var copy=widget
            if let id=copy.hostID,let target=machineMapping[id],!target.isEmpty {copy.hostID=target}
            return copy
        }
        result.textScale=source.textScale;result.snapToGrid=source.snapToGrid
        if kind == .setup {
            for var host in source.remoteHosts {
                guard !result.remoteHosts.contains(where:{$0.destination == host.destination && $0.collectorPath == host.collectorPath}) else {continue}
                if result.remoteHosts.contains(where:{$0.id == host.id}) {host.id=UUID()}
                result.remoteHosts.append(host)
            }
        }
        result.repairGeometry()
        return result
    }

    private func validate() throws {
        guard format == "dev.wokintosh.setup",version == 1 else {throw SetupTransferError.unsupported}
        guard Set(widgets.map(\.id)).count == widgets.count,
              Set(remoteHosts.map(\.id)).count == remoteHosts.count,
              Set(machines.map(\.id)).count == machines.count else {throw SetupTransferError.duplicateIDs}
        guard machines.filter(\.isLocal).count<=1,
              machines.allSatisfy({!$0.id.isEmpty && (!$0.isLocal || $0.remoteHostID == nil)}) else {throw SetupTransferError.invalidMachine}
        for reference in machines {
            if let configID=reference.remoteHostID,!remoteHosts.contains(where:{$0.id == configID}) {throw SetupTransferError.invalidMachine}
        }
        guard remoteHosts.allSatisfy({RemoteCommand.isValidDestination($0.destination) && RemoteCommand.isValidCollectorPath($0.collectorPath)}) else {throw SetupTransferError.invalidMachine}
    }

    private func sanitizedTemplate()->DashboardSetup {
        var result=self
        result.remoteHosts=[];result.machines=[]
        result.widgets=widgets.map { original in
            var widget=original;widget.id=UUID();widget.hostID=nil
            widget.systemOptions.driveIDs=nil
            widget.calendarOptions.calendarIDs=[];widget.calendarOptions.excludedTitlePatterns=[]
            widget.weatherOptions.place="";widget.weatherOptions.latitude=nil;widget.weatherOptions.longitude=nil
            widget.action=WidgetAction()
            return widget
        }
        return result
    }
}
